# GPT-5.6 Sol Command Center (sol-luna)

> 把 **Sol (the agent)** 的修理 / 审核任务打包成可验证的 **execution packet**，
> 交给 **ChatGPT Web GPT-5.6 Luna Max**（或本地 `luna_worker` agent）执行，
> 再收回结果并沉淀为供 Sol 直接使用的 **summary**。

```
Sol (Codex) --packet--> ChatGPT Web GPT-5.6 Luna Max --result--> Sol (summary)
```

**设计原则（硬约束，绝不静默降级）**

1. **永远绑定 `gpt-5.6-luna` + `effort=max`**。工具任何路径都不得悄悄换模型、换 effort、降精度。
2. **payload 尺寸硬上限 12 000 字节**（UTF-8 字节数），超限直接报错，不截断。
3. **hash 绑定**：`dispatch` 前重算 `payload_sha256`，不一致就退出 `3`，拒绝在已篡改的内容上运行。
4. **可审计**：每次事件都追加写入状态目录下的 `journal.jsonl`；execution packet 携带完整状态机。
5. **不静默降级传输**：`web-*` 只推送人工代理（仅落盘 stage 文件，不碰剪贴板），`local-worker` 只调用**原生** `codex.exe`。PATH 上只有 `.cmd`/`.bat` shim（npm/pnpm 安装形态）时不再直接失败，而是解析出该 shim 背后真正要启动的原生 `codex.exe` 并直接调用——payload 绝不经过 `cmd.exe`，防 BatBadBut 参数注入；解析不出原生可执行文件时才报错拒绝（退出 `2`）。也可用 `SOL_LUNA_CODEX_BIN` 显式指定原生 `codex.exe`。
6. `init` **绝不自动改 `~/.codex/config.toml`**，只输出建议（样例在 `config/config.toml.example`）。

## 状态目录

默认 `<插件目录>/.sol-luna-state`（packets / results / journal.jsonl，已加入 `.gitignore`）。
可用环境变量 **`SOL_LUNA_STATE_DIR`** 重定向到任意目录（CI / 测试沙箱 / 免污染仓库）。
配套变量：`CODEX_HOME`（agent/skill 安装位置）。

## 状态机

每个 packet 沿单向固定状态机推进：
`new → done → ingested → summarized`（`dispatch` / `ingest` / `summary` 各前进一格）。
乱序操作（未 dispatch 先 ingest、已 summarized 再 ingest、对非 `new` 状态二次 dispatch）退出 `1` 拒绝；
损坏的 execution.json 退出 `2`（显式查询报错，批量 `status` 跳过坏行继续）。


## 目录结构

```
scripts/sol-luna.ps1      Windows 传输（doctor/init/packet/dispatch/ingest/summary/status）
scripts/sol-luna.sh       macOS/Linux/ARM 传输（行为镜像，纯 POSIX userland：bash+coreutils+awk）
agents/luna-worker.toml   Codex 自定义 agent（远程 worker 模式）
skills/sol-command-center/  落库技能
templates/AGENTS.md       注入到仓库根的规则片段
config/config.toml.example 建议的 Codex 配置（不自动写入）
examples/fix-http-reset.spec.json  参考 spec
tests/run-tests.ps1       Windows 集成测试（沙箱化 CODEX_HOME + SOL_LUNA_STATE_DIR）
tests/run-tests.sh        POSIX 集成测试（同上，行为镜像）
tests/run-interop.sh      跨平台互操作测试（ps1 写的状态目录 sh 读，反向亦然）
```

## 快速开始

```bash
# 1. 自检（JSON verdict + 退出码）
bash sol-luna.sh doctor            # *nix / ARM
powershell -File scripts\sol-luna.ps1 doctor   # Windows

# 2. 首次安装（写 agent + skill + AGENTS.md 规则；不改 config.toml）
bash sol-luna.sh init

# 3. 打包
bash sol-luna.sh new-packet --spec examples/fix-http-reset.spec.json

# 4. 分发
bash sol-luna.sh dispatch --id <id> --transport web-manual   # 人工：粘贴到 chatgpt.com
bash sol-luna.sh dispatch --id <id> --transport local-worker # 自动：codex exec [--model gpt-5.6-luna -c model_reasoning_effort=max] <prompt>

# 5. 收回 & 汇总
bash sol-luna.sh ingest --id <id> --result <result-file>
bash sol-luna.sh summary --id <id> --text-file <summary.txt>

# 6. 状态
bash sol-luna.sh status
```

## 传输对照

| transport      | 谁来跑 | 何时用 |
|----------------|--------|--------|
| `local-worker` | `codex exec --skip-git-repo-check --model gpt-5.6-luna -c model_reasoning_effort=max <prompt>` | 本地 `codex` 是原生 `.exe`，或 PATH 上是 npm/pnpm 的 `.cmd` shim 而能解析出其背后的原生 `codex.exe`；两者都不可得则报错（不降级）。可用 `SOL_LUNA_CODEX_BIN` 显式钉死原生 `codex.exe`。agent 的 model/effort 由 `-m`/`-c` 传入。GUI 不拦截：除非 worker 在 `-TimeoutSec`/`--timeout`（默认 900，单位是**无进展秒数**，不是总时长）内完全没有 CPU 进展，否则不会杀掉一个仍在生成的长审计。 |
| `web-desktop`  | 人工：ChatGPT 桌面 App 内置浏览器 | 桌面端会话 |
| `web-manual`   | 人工：任何浏览器的 chatgpt.com | 兜底，零依赖 |

规则：worker 回传必须**先审后收**。`ingest` 只落文件与 hash；
是否采纳结果由上游指挥中心的后续关卡决定，工具本身**不**自动合并改动。

## 退出码

`0` 成功 · `1` 用法/校验 · `2` 运行时 · `3` hash 失配（拒绝运行 degraded 内容）

## 已验证的误用拒绝（tests）

见 `tests/`（Windows 与 POSIX 双套件）。覆盖：缺 payload、缺 codex、缺 spec.goal、
doctor 缺 agent 退出 `2`、dispatch hash 失配退出 `3`、非 `new` 状态拒绝二次 dispatch、
先 ingest 后 dispatch 的顺序违规拒绝、非法 id（路径穿越形态）拒绝、
损坏的 execution.json（状态机路径 / 显式 status 查询）退出 `2`（批量列举跳过）、
payload 超过 12 000 字节硬限退出 `2`（不截断、不静默放行）、spec 文档为 JSON
`null` 退出 `1`、`--timeout` 限长防算术溢出且上界 86 400 秒（单位是**无进展秒数**而非总时长——一个仍在生成的长审计不会被墙钟杀掉）、非 ASCII 数字
超时值退出 `1`（且无 CPU 源时 watchdog 自动失效，宁可等待也不误杀）、目录冒充 spec/result/text 文件退出 `1`（`-f` / `-PathType Leaf`）、
未知选项与多余位置参数在解析期退出 `1`（白名单拒绝，两侧一致）、纯空白 `goal` 退出 `1`。

跨平台互操作（`tests/run-interop.sh`，需 Windows 上带 bash；纯 POSIX 无 powershell 时自动跳过）：
验证两种实现共享同一个 `SOL_LUNA_STATE_DIR`——ps1 写的多行 execution.json sh 的
awk 解析器能读、sh 写的单行 json ps1 的 `ConvertFrom-Json` 能读，三个交叉场景
（ps1 建→sh 派发/摄取/汇总、ps1 派发→sh 摄取、sh 建→ps1 派发）全部走通，
并校验两侧落盘的 keyset 形状一致（扁平 canonical 键集、无嵌套 `result` 对象）。

## 安全要点

- packet id 仅允许 `A-Za-z0-9._-`，且最长 60 字符；所有由 id 拼接的路径先过校验（无路径穿越）。
- `dispatch` 前强制重算 payload SHA-256，且两侧都校验摘要形状（64 位十六进制；畸形/截断 hash 一律拒绝，杜绝空值互等的假通过）；结果/summary 同样 hash 绑定（按原始字节，无 BOM）。
- `local-worker` 仅调用原生 `codex.exe`：PATH 上只有 `.cmd`/`.bat` shim 时，先解析出该 shim 真正要启动的原生 `codex.exe`（npm/pnpm 的 `@openai/codex` vendor 布局）再直接 CreateProcess，**绝不执行 shim**（否则 payload 会被 `cmd.exe` 重新解析）；解析不出就拒绝。payload 经 Win32 argv 规则整体加引号后作为**单个**参数传递（防注入/防 BatBadBut）。
- dispatch 使用原子锁（`CreateNew` / noclobber），防同一 packet 并发双跑；>1h 的死进程遗留锁才回收；无法确定锁年龄时**绝不**抢锁。
- execution.json / payload 写入均为 tmp+rename 原子写；web 传输不写剪贴板（避免敏感内容外泄到共享边界）。
- **内存边界（防 OOM / 无上限读取）**：spec / execution.json / result / summary / payload 一律先过 1 MB 上限再读取；超过即拒绝（不截断、不静默放行）。local-worker 子进程 stdout 超限同样拒绝并留档（`result-oversize.log`），绝不悄悄截断。journal 迁移探测只读前 64 KB，不整文件 slurp。
- execution.json / payload 写入均为 tmp+rename 原子写；web 传输不写剪贴板（避免敏感内容外泄到共享边界）。

## License

MIT（见 `LICENSE`）。

> 使用 ChatGPT Web GPT-5.6 Luna Max 执行任务时请确认你的计划/订阅可获得该模型；
> 本工具只编排语义，不代替用户在 OpenAI 网页上的账号/许可校验。