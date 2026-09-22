# 使用方法和步骤

以下命令在**仓库根目录**执行。Windows 用 `powershell -File ...`，
macOS / Linux / ARM 把 `scripts\astra-luna.ps1` 换成 `scripts/astra-luna.sh`，
选项 `-Id / -Transport / -SpecFile` 换成 `--id / --transport / --spec`。

## 一、安装

### 方式 A：Codex 插件市场（推荐）

1. `git clone https://github.com/iradvmmi2028/Codex2AnyAPI.git`
2. 打开 Codex → **插件** → **添加** → **添加插件市场**。
3. 选择仓库根目录（含 `.agents/plugins/marketplace.json` 的那个）。
4. 列表中出现 `astra-luna-command-center` → 点 **安装**。
5. 重启 / 重载会话，让技能生效。

### 方式 B：init（装 agent + skill + 规则）

插件市场只注册插件包；worker agent、技能、`AGENTS.md` 路由规则由 `init` 落盘：

```powershell
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 init
```

幂等，可重复执行；**不会**修改 `~/.codex/config.toml`，只打印建议配置
（样例见 `plugins/astra-luna-command-center/config/config.toml.example`）。

### 验证

```powershell
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 doctor
```

退出码 `0` 且 `agent_toml: true`、`local_worker: true` 即健康；
缺什么它会直接打印对应的 `init` 命令。

## 二、配置 worker（三选一）

| 路线 | 适用 | 命令 |
|------|------|------|
| 默认 `gpt-5.6-luna` | 本机有原生 `codex.exe` 且带该模型 | 无需配置 |
| **astra-Diy 任意 API** | 本地 Ollama / 中转站 / 自建服务 | 见下 |
| `web-manual` | 什么都没装 | 无需配置，人工粘贴 |

### astra-Diy 配置（Codex2AnyAPI 主场景）

三种入口任选，写入的是同一份 `<state_dir>/diy.json`：

```powershell
# ① Windows 文本框对话框（有连通测试 + 模型下拉）
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 diy-settings

# ② 纯 CLI
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 diy-set `
  -BaseUrl "http://127.0.0.1:11434/v1" -ApiKey "sk-..." -Model "qwen2.5-coder:32b" `
  -Enabled true -ReplaceLuna true

# ③ 浏览器设置页：仓库根双击打开 index.html
#    填 Base URL / API Key / Model → 测试连接 → 导出 diy.json
#    覆盖到 C:\Users\<你>\.codex\skills\astra-command-center\.astra-luna-state\diy.json
```

配套检查：

```powershell
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 diy-test    # 鉴权/连通
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 diy-models   # 拉模型列表
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 diy-show     # 查看（Key 掩码）
```

会话内也可直接输入 `/astra-Diy`（重启 Codex 后生效）。
`enabled=true` 且 `replace_luna=true` 时，后续 dispatch 默认走 `diy-openai`；
配置不完整或连通失败会**显式报错**，不会偷偷改回 Luna。

## 三、跑一个完整任务

```powershell
$P = "plugins\astra-luna-command-center\scripts\astra-luna.ps1"

# 1. 写 spec：参考 examples/fix-http-reset.spec.json
#    必填 goal，另加 scope / inputs / acceptance criteria / file boundaries

# 2. 打包（生成 packets/<id>/，payload ≤ 12 000 字节）
powershell -File $P new-packet -SpecFile examples\fix-http-reset.spec.json

# 3. 派发（四选一，显式指定，不会静默换）
powershell -File $P dispatch -Id <id> -Transport local-worker   # codex exec + gpt-5.6-luna
powershell -File $P dispatch -Id <id> -Transport diy-openai     # astra-Diy 自定义 API
powershell -File $P dispatch -Id <id> -Transport web-manual     # 落盘 payload，人工粘贴 chatgpt.com
powershell -File $P dispatch -Id <id> -Transport chatgpt-web    # 浏览器自动化

# 4. worker 干完，收回结果（先审后收，工具不自动合并）
powershell -File $P ingest -Id <id> -ResultFile results\<id>.result.md

# 5. 沉淀 summary 供指挥塔直接使用
powershell -File $P summary -Id <id> -TextFile results\<id>.summary.md

# 6. 随时看进度
powershell -File $P status
```

状态机 `new → done → ingested → summarized` 单向推进；顺序不对直接退出 `1`。

## 四、测试

```powershell
# Windows 集成测试（沙箱化 CODEX_HOME 与状态目录，不污染真实环境）
powershell -ExecutionPolicy Bypass -File plugins\astra-luna-command-center\tests\run-tests.ps1

# POSIX
bash plugins/astra-luna-command-center/tests/run-tests.sh

# 跨平台互操作（ps1 与 sh 读写同一状态目录交叉验证）
bash plugins/astra-luna-command-center/tests/run-interop.sh
```

`sol-luna-command-center` 的 `tests/` 用法相同，把路径里的 `astra` 换成 `sol`。

## 五、故障排查

| 现象 | 处理 |
|------|------|
| `doctor` 退出 `2`、`agent_toml: false` | 跑一次 `init` |
| `local-worker` 报缺 codex | 装原生 `codex.exe` 到 PATH，或改用 `web-manual` / `diy-openai` |
| dispatch 退出 `3` | payload 被改动过，重新 `new-packet` |
| DIY 测试连通失败 | 检查 Base URL 是否含 `/v1`、Key 是否有效、`diy-show` 是否 `enabled` |
| 想临时回到 Luna 路线 | `diy-set -Enabled false` 或取消 `replace_luna` |
| 状态目录被污染 / CI 里跑 | 用环境变量 `ASTRA_LUNA_STATE_DIR`、`CODEX_HOME`、`ASTRA_DIY_CONFIG` 重定向 |
| 查审计轨迹 | 看状态目录里的 `journal.jsonl`（每次事件一行） |

退出码：`0` 成功 · `1` 用法/校验 · `2` 运行时 · `3` hash 失配或 DIY 配置不完整。

## 六、卸载

`init` 写入的内容都可手工还原：删除 `~/.codex/agents/astra-*.toml`、
`~/.codex/skills/astra-command-center/`，并把 `AGENTS.md` 中
`<!-- astra-luna:begin -->` 到 `<!-- astra-luna:end -->` 的标记块删掉；
再从 Codex 插件列表移除插件即可。状态目录 `.astra-luna-state/` 按需整体删除。
