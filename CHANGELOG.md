# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

版本号的单一事实来源：各插件的 `package.json` 与 `.codex-plugin/plugin.json`
（两处必须一致），发布时打 annotated tag `v<主>.<次>.<修>`。

## [Unreleased]

### Added
- 仓库级 README、架构说明（docs/ARCHITECTURE.md）、使用步骤（docs/USAGE.md）。
- 仓库级 `.gitignore`：排除运行状态、浏览器 profile、DIY 密钥、打包产物与调研草稿。

## [0.2.0] - 2026-09-14

### Added
- **astra-Diy**：任意 OpenAI 兼容 API 作为 worker 执行位
  （`diy-set` / `diy-show` / `diy-test` / `diy-models` / `diy-schema` / `diy-settings`）。
- 浏览器图形设置页（根目录 `index.html` + `css/` + `js/`），导出 `diy.json` 生效。
- 微信 OpenAI 网关传输（`wechat-chatapi.py`）。
- 五个 Luna worker 角色 agent（explorer / worker / tester / reviewer / researcher）。
- `/astra-Diy` 会话命令与 `astra-diy` 技能。
- dispatch 单次读取快照哈希绑定，杜绝校验与发送之间的调包窗口。

### Changed
- dispatch 默认路由：DIY `replace_luna=true` 时走 `diy-openai`，否则 `local-worker`。
- summary 采用「先复制后哈希」，`summary_sha256` 永远对最终落盘副本计算。

## [0.1.0] - 2026-09-11

### Added
- `sol-luna-command-center`：execution packet 编排（`new-packet` / `dispatch` /
  `ingest` / `summary` / `status` / `doctor` / `init`）。
- 双平台镜像实现（`.ps1` / `.sh`）与跨平台互操作测试。
- 状态机 `new → done → ingested → summarized`、SHA-256 绑定、journal 审计、
  原子锁与 12 000 字节 payload 硬上限。
- `local-worker` 仅调用原生 `codex.exe`（解析 npm shim，防 BatBadBut）。
