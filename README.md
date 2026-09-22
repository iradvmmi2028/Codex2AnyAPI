# Codex2AnyAPI

把 **Codex（GPT-6 Astra 总指挥）** 的执行任务分发给任意 worker 的本地插件集合，
其中 **astra-Diy** 支持把执行位替换成**任何 OpenAI 兼容 API**（本地 Ollama、
中转站、微信 OpenAI 网关、自建 vLLM…），这就是仓库名 Codex2AnyAPI 的由来。

```
GPT-6 Astra（指挥塔）──execution packet──▶ worker（gpt-5.6-luna | 任意 OpenAI 兼容 API）
        ▲                                          │
        └────────── hash 绑定 result + summary ◀───┘
```

- 指挥权永远在 Astra：DIY worker 只接管「执行」这一格，不参与审核与验收。
- 所有交接都走 **execution packet**，SHA-256 双向绑定，状态机单向推进，
  不静默降级、不悄悄换模型。

## 仓库里有什么

| 路径 | 说明 | 版本 |
|------|------|------|
| `plugins/astra-luna-command-center/` | 主插件：packet 编排 + astra-Diy 自定义模型 + 五个 Luna worker agent | 0.2.0 |
| `plugins/sol-luna-command-center/` | 前代插件（GPT-5.6 Sol 版），可独立使用 | 0.1.0 |
| `index.html` / `css/` / `js/` | astra-Diy 图形设置页（浏览器打开，导出 `diy.json` 生效） | 同主插件 |
| `.agents/plugins/marketplace.json` | 本地插件市场索引，Codex 指向本仓库即可安装两个插件 | — |
| `docs/ARCHITECTURE.md` | 架构说明（分层、状态机、传输层、安全设计） | — |
| `docs/USAGE.md` | 使用方法与完整步骤（安装 → 配置 → 执行 → 验收） | — |
| `INSTALL.md` | 插件安装的精简版说明 | — |

不入库的内容（见 `.gitignore`）：`.astra-luna-state/`、`.sol-luna-state/`
（含浏览器登录 profile、packet 载荷、`diy.json` API 密钥）、`*.zip` / `*.rar`
打包产物、`_research/` 调研草稿、`.spidercode/` 本机会话。

## 快速开始

```powershell
# 1. 拿到仓库
git clone https://github.com/iradvmmi2028/Codex2AnyAPI.git
cd Codex2AnyAPI

# 2. Codex 里注册本地插件市场（指向本目录，含 .agents/plugins/marketplace.json）
#    Codex → 插件 → 添加 → 添加插件市场 → 选择本仓库根目录 → 安装 astra-luna-command-center

# 3. 初始化（装 agent + skill + AGENTS.md 规则；幂等，不改 config.toml）
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 init

# 4. 自检
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 doctor

# 5. 配置自定义 API 执行位（可选，缺省走 gpt-5.6-luna）
powershell -File plugins\astra-luna-command-center\scripts\astra-luna.ps1 diy-settings
```

完整的执行流程与排错见 **[docs/USAGE.md](docs/USAGE.md)**，
设计原理见 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**。

## 版本管理

- 语义化版本，**单一事实来源**是每个插件的 `package.json` 与
  `.codex-plugin/plugin.json`（两处必须一致）。
- 每次发布打 annotated tag：`v<主>.<次>.<修>`，例如 `v0.2.0`。
- 变更记录在 [CHANGELOG.md](CHANGELOG.md)（Keep a Changelog 格式）。
- 发布新版本的步骤：

```powershell
# 1. 同步两个文件里的 version
# 2. 更新 CHANGELOG.md
git add -A; git commit -m "release: astra-luna-command-center v0.3.0"
git tag -a v0.3.0 -m "v0.3.0"
git push origin main --follow-tags
```

## 运行要求

- Windows：PowerShell 5.1+；macOS / Linux / ARM：bash + coreutils + awk。
- `local-worker` 传输需要原生 `codex.exe` 在 PATH 上；否则用 `web-manual`
  或配置 astra-Diy 走任意 OpenAI 兼容 API。
- astra-Diy 需要 `python`（3.8+）执行 `scripts/openai-diy.py`。

## License

MIT — 各插件目录内含 `LICENSE`。
