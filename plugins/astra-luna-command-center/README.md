# GPT-6 Astra Command Center (astra-luna)

> 把 **GPT-6 Astra (the agent)** 的修理 / 审核任务打包成可验证的 **execution packet**，
> 交给 worker 舰队执行（默认 **`gpt-5.6-luna`** + `max`；或 **astra-Diy** 自定义
> OpenAI 兼容模型），再收回结果并沉淀为供 Astra 直接使用的 **summary**。
> 方案来源：《目前最聪明的 Codex 省额度方案：Astra 当总指挥，Luna 批量干活》
> （codex-astra-luna-orchestrator 思路），本插件是其可执行、可审计的工程化实现。

```
GPT-6 Astra (Codex)        worker (luna-max | diy-openai)     GPT-6 Astra (Codex)
plan + RCA  ──packet──▶  execute within scope          ──result──▶  ingest + review + summary
```

**模型绑定**

| 角色 | 模型 | 说明 |
|------|------|------|
| 总指挥（本 Codex 会话） | `gpt-6-astra` | `high`；永不外包 |
| 默认执行 worker | `gpt-5.6-luna` | `max`（local-worker） |
| **astra-Diy 自定义 worker** | 任意 OpenAI 兼容 model id | 启用后**仅替换** luna 执行位；Astra 仍审核批准 |

**设计原则（硬约束，绝不静默降级）**

1. **默认永远绑定 `gpt-5.6-luna` + `effort=max`**。工具任何路径都不得悄悄换模型；启用 **astra-Diy** 且 `replace_luna=true` 时，dispatch 默认改走 `diy-openai`（用户自填 Base URL / API Key / Model）。总指挥侧仍由 `config.toml` 固定 `gpt-6-astra` + `high`。
2. **payload 尺寸硬上限 12 000 字节**（UTF-8 字节数），超限直接报错，不截断。
3. **hash 绑定**：`dispatch` 先做**单次读取快照**——对同一份字节既算哈希又发给 worker，杜绝"先校验后重读"窗口内被调包；不一致就退出 `3`。
4. **可审计**：每次事件都追加写入状态目录下的 `journal.jsonl`；execution packet 携带完整状态机。
5. **不静默降级传输**：`web-manual` 只推送人工代理，`local-worker` 只调用**原生** `codex.exe`；`diy-openai` 只调用用户配置的 OpenAI 兼容 API。配置不完整或连通失败一律显式失败，**绝不**悄悄改回 Luna。
6. `init` **绝不自动改 `~/.codex/config.toml`**，只输出建议；**绝不覆盖其他插件的文件**。
7. **summary 先复制后哈希**：`summary_sha256` 永远对最终落盘副本计算。

## astra-Diy：自定义 / 本地 OpenAI 兼容模型

在插件中启用 `/astra-Diy` 后，可用文本框（Windows 对话框）或 CLI 配置：

| 字段 | 说明 |
|------|------|
| **Base URL** | OpenAI 兼容接口根，如 `http://127.0.0.1:11434/v1` 或 `https://api.example.com/v1` |
| **API Key** | Bearer Token（`sk-...` 或提供商密钥） |
| **Model** | 自定义模型 id（替换 `gpt-5.6-luna` 的执行位） |

```powershell
# 打开设置对话框（Base URL / API Key / Model 文本框 + 连通测试 + 模型获取）
powershell -File scripts\astra-luna.ps1 diy-settings

# 或 CLI
powershell -File scripts\astra-luna.ps1 diy-set -BaseUrl "http://127.0.0.1:11434/v1" -ApiKey "sk-..." -Model "qwen2.5-coder:32b" -Enabled true -ReplaceLuna true
powershell -File scripts\astra-luna.ps1 diy-test     # 连接 / 鉴权测试 (GET /models)
powershell -File scripts\astra-luna.ps1 diy-models   # 拉取提供商模型列表
powershell -File scripts\astra-luna.ps1 diy-show     # 状态（API Key 掩码显示）
```

架构不变：**GPT-6 Astra 发起请求 → DIY API 模型干活（返回 md / 代码修改说明）→ GPT-6 Astra 审核批准**。DIY 只替换 worker，不夺走指挥权。

配置文件：`<state_dir>/diy.json`（可用 `ASTRA_DIY_CONFIG` 重定向；`ASTRA_DIY_API_KEY` 可覆盖密钥）。  
字段说明见 `config/diy-settings.example.json`；命令技能见 `commands/astra-Diy.md` 与 `skills/astra-diy/`。

## Luna worker 舰队（agents/）

按文章的五个固定角色，全部钉死 `gpt-5.6-luna` + `model_reasoning_effort = "max"`：

| 文件 | agent | 职责 |
|------|-------|------|
| `agents/astra-explorer.toml`   | `astra_explorer`   | 只读侦察：仓库拓扑、文件依赖扫描 |
| `agents/astra-worker.toml`     | `astra_worker`     | 有界代码实现与文件修改 |
| `agents/astra-tester.toml`     | `astra_tester`     | 自动化测试（只动范围内测试文件） |
| `agents/astra-reviewer.toml`   | `astra_reviewer`   | 独立代码评审与安全检查（只读） |
| `agents/astra-researcher.toml` | `astra_researcher` | 外部文档与依赖调研（只读，附出处） |

`init` 会把五个角色文件装到 `~/.codex/agents/`（已存在的同名文件原样保留，幂等可重复执行）。

## 状态目录

默认 `<插件目录>/.astra-luna-state`（packets / results / journal.jsonl / diy.json，已加入 `.gitignore`）。
可用环境变量 **`ASTRA_LUNA_STATE_DIR`** 重定向到任意目录（CI / 测试沙箱 / 免污染仓库）。
配套变量：`CODEX_HOME`（agent/skill 安装位置）、`ASTRA_DIY_CONFIG`、`ASTRA_DIY_API_KEY`、`ASTRA_DIY_BIN`、`ASTRA_LUNA_PYTHON`。
POSIX 侧创建状态目录时强制 `umask 077` 并 `chmod 700`：packet payload 与结果可能含敏感内容，默认不对其他用户可读。

## 状态机

每个 packet 沿单向固定状态机推进：
`new → done → ingested → summarized`（`dispatch` / `ingest` / `summary` 各前进一格）。
乱序操作退出 `1` 拒绝；损坏的 execution.json 退出 `2`。

## 传输对照（含 diy-openai）

| transport | 谁跑 | 何时用 |
|-----------|------|--------|
| `local-worker` | `codex exec --model gpt-5.6-luna -c model_reasoning_effort=max` | 默认；显式指定时始终钉死 luna 对 |
| `diy-openai` | `scripts/openai-diy.py` → OpenAI 兼容 `/v1/chat/completions` | 用户已配置 astra-Diy 且 `replace_luna=true` 时的默认传输 |
| `chatgpt-web` | 浏览器自动化 | 无本地 worker、用户同意时 |
| `web-manual` | 人工粘贴 | 兜底，零依赖 |

规则：worker 回传必须**先审后收**。`ingest` 只落文件与 hash；是否采纳由 Astra 决定，工具不自动合并。

## 目录结构

```
scripts/astra-luna.ps1     Windows 传输（doctor/init/packet/dispatch/ingest/summary/status/diy-*）
scripts/astra-luna.sh      macOS/Linux/ARM 传输（行为镜像）
scripts/openai-diy.py      OpenAI 兼容 DIY 客户端（test/models/chat/run）
scripts/diy-settings.ps1   Windows DIY 设置对话框（文本框）
scripts/chatgpt-web.py     ChatGPT Web transport
agents/astra-*.toml        五个 luna 角色 agent
skills/astra-command-center/  指挥中心技能
skills/astra-diy/          astra-Diy 技能
commands/astra-Diy.md      /astra-Diy 命令
templates/AGENTS.md        注入规则片段
config/config.toml.example Codex 配置建议
config/diy-settings.example.json  DIY 设置字段说明
```

## 退出码

`0` 成功 · `1` 用法/校验 · `2` 运行时 · `3` hash 失配 **或 DIY 配置不完整**

## License

MIT — see `LICENSE`.
