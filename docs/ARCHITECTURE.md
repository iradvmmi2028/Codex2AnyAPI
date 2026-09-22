# 架构说明

## 1. 设计目标

Codex 会话（总指挥）聪明但额度有限；大量机械执行（批量改文件、跑测试、
调研）交给便宜或本地的 worker。要解决三个问题：

1. **交接不失真** —— 任务必须自包含、有边界、可验收。
2. **结果可信任** —— worker 回传的内容必须证明「就是当初派出去的那份」。
3. **降级可见** —— 任何换模型、换通道都必须显式失败，绝不静默发生。

## 2. 分层

```
┌─────────────────────────────────────────────────────────┐
│ 指挥层  GPT-6 Astra（Codex 会话）                        │
│   需求拆解 / 根因判断 / 审核验收 / 最终答复               │
│   规则固化在 AGENTS.md（由 init 注入，带 begin/end 标记） │
├─────────────────────────────────────────────────────────┤
│ 编排层  astra-luna.ps1 / astra-luna.sh（行为镜像双实现）  │
│   new-packet → dispatch → ingest → summary → status     │
│   状态机、SHA-256 绑定、锁、journal 审计、尺寸上限        │
├─────────────────────────────────────────────────────────┤
│ 传输层  四种 transport，显式选择、互不静默替代            │
│   local-worker  codex exec --model gpt-5.6-luna ...     │
│   diy-openai    openai-diy.py → /v1/chat/completions    │
│   chatgpt-web   浏览器自动化（chatgpt-web.py）           │
│   web-manual    人工粘贴，零依赖兜底                      │
├─────────────────────────────────────────────────────────┤
│ 状态层  <插件>/.astra-luna-state/（git 忽略）             │
│   packets/  results/  journal.jsonl  diy.json           │
└─────────────────────────────────────────────────────────┘
```

编排层的 `.ps1` 与 `.sh` 是**双胞胎实现**：同一套子命令、同一套选项白名单、
同一份状态目录格式（`tests/run-interop.sh` 验证 ps1 写的目录 sh 能读、反向亦然）。

## 3. Execution packet 与状态机

一个任务 = 一个 spec JSON → 一个 packet 目录：

```
spec.json ──new-packet──▶ packets/<id>/payload.md        （≤ 12 000 字节）
                          packets/<id>/execution.json    （状态机 + payload_sha256）
dispatch ──▶ status: new → done
ingest   ──▶ status: done → ingested   （结果按原始字节算 hash 落 results/）
summary  ──▶ status: ingested → summarized（summary 先复制后哈希）
```

- 单向推进；乱序操作（未 dispatch 先 ingest、二次 dispatch）退出 `1` 拒绝。
- `dispatch` 做**单次读取快照**：同一份字节既算哈希又发给 worker，
  杜绝「先校验后重读」窗口内被调包；不匹配退出 `3`。
- 每一步追加 `journal.jsonl`，可回放审计。
- packet id 只允许 `A-Za-z0-9._-` 且 ≤ 60 字符，拼路径前先校验（防路径穿越）。
- dispatch 用原子锁（CreateNew / noclobber）防同一 packet 并发双跑。

## 4. astra-Diy：Codex2AnyAPI 的核心

astra-Diy 不新开一条指挥链，只替换状态机里「worker 执行」那一格：

```
diy.json ──▶ openai-diy.py ──POST /v1/chat/completions──▶ 任意 OpenAI 兼容端点
                │  test / models / chat / run 四个子命令
                └─ 失败即显式退出，绝不回落 gpt-5.6-luna
```

- 配置：`base_url` + `api_key` + `model`（+ `temperature` / `timeout_sec`）。
  落在 `<state_dir>/diy.json`（git 忽略），`ASTRA_DIY_API_KEY` 可覆盖密钥，
  `ASTRA_DIY_CONFIG` 可重定向配置路径。
- `replace_luna=true` 时 dispatch 默认走 `diy-openai`；
  `enabled=false` 立刻回到 luna 路线。
- 模型列表来自 `GET /v1/models`，设置页与 `diy-models` 共用该逻辑。
- 支持两类端点：标准 OpenAI 兼容、以及微信 OpenAI 网关（`wechat-chatapi.py`，
  Token 签名，无需 APPID）。

配置入口有三个，写的是同一份 `diy.json`：

| 入口 | 命令 / 文件 |
|------|-------------|
| CLI | `astra-luna.ps1 diy-set / diy-show / diy-test / diy-models` |
| Windows 文本框对话框 | `astra-luna.ps1 diy-settings`（内部 `diy-settings.ps1`） |
| 浏览器设置页 | 仓库根 `index.html` → 导出 `diy.json` 或复制 CLI |

## 5. Worker 舰队（agents/）

五个角色全部钉死 `gpt-5.6-luna` + `model_reasoning_effort = "max"`，
由 `init` 装进 `~/.codex/agents/`（同名已存在则保留，幂等）：

| agent | 职责 | 读写 |
|-------|------|------|
| `astra_explorer` | 仓库拓扑 / 依赖扫描 | 只读 |
| `astra_worker`   | 有界代码实现 | 写（范围内） |
| `astra_tester`   | 跑测试 | 只动范围内测试文件 |
| `astra_reviewer` | 代码与安全评审 | 只读 |
| `astra_researcher` | 外部文档调研 | 只读，附出处 |

worker 被明确禁止：再派 agent、改架构、做破坏性改动、碰范围外文件。

## 6. 安全边界

- **尺寸上限**：payload 12 000 UTF-8 字节；spec / execution.json / result /
  summary 一律先过 1 MB 上限再读，超限拒绝不截断。
- **注入防护**：`local-worker` 只调原生 `codex.exe`；PATH 上只有 npm 的
  `.cmd` shim 时先解析出背后原生 exe 再直接 CreateProcess，**绝不经过
  `cmd.exe`**（防 BatBadBut），payload 按 Win32 argv 规则整体加引号单参传递。
- **原子写**：execution.json / payload 都是 tmp+rename；web 传输不碰剪贴板。
- **权限**：POSIX 侧状态目录 `umask 077` / `chmod 700`。
- **不改配置**：`init` 绝不自动改 `~/.codex/config.toml`，只输出建议
  （样例在 `config/config.toml.example`），也绝不覆盖其他插件的文件。

## 7. 退出码约定

两套实现一致：`0` 成功 · `1` 用法/校验 · `2` 运行时 ·
`3` hash 失配或 DIY 配置不完整。

## 8. 目录 → 架构映射

```
plugins/astra-luna-command-center/
├── scripts/astra-luna.{ps1,sh}   编排层 + 传输层入口
├── scripts/openai-diy.py         diy-openai 客户端
├── scripts/wechat-chatapi.py     微信网关客户端
├── scripts/chatgpt-web.py        chatgpt-web 传输
├── scripts/diy-settings.ps1      Windows 设置对话框
├── agents/astra-*.toml           worker 舰队定义
├── skills/                       指挥中心 + astra-Diy 技能（按需加载）
├── commands/astra-Diy.md         /astra-Diy 会话命令
├── templates/AGENTS.md           注入仓库根的指挥规则片段
├── config/*.example              配置样例（永不自动应用）
├── examples/*.spec.json          参考 spec
└── tests/                        ps1 / sh / 跨平台互操作三套测试
```
