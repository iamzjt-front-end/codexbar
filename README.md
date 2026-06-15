# CodexAppBar

A macOS menu bar app for managing multiple ChatGPT/Codex accounts. Switch accounts instantly and monitor quota usage without opening a browser.

> **中文说明见下方 / Chinese version below**

---

![CodexAppBar English](en.png)

## Features

- **Multi-account management** — Add unlimited ChatGPT accounts via OAuth
- **Quota monitoring** — Tracks both the 5-hour rolling window and the weekly quota in real time
- **Account switching** *(experimental)* — Writes the selected account to `~/.codex/auth.json`; requires quitting Codex.app to take effect. If using subagents, prefer logging out from within Codex.app instead
- **Auto refresh** — Active account refreshes every 10 seconds while the menu is open; all accounts refresh every 5 minutes in the background
- **Status indicators** — Color-coded badges and menu bar icon reflect account health (normal / warning / quota exhausted / suspended)
- **Animated UI** — Progress bars and percentages animate on update

## Requirements

- macOS 13 Ventura or later
- [Codex](https://github.com/openai/codex) desktop app installed at `/Applications/Codex.app`

## Installation

1. Clone the repository:
   ```sh
   git clone https://github.com/yourname/codexBar.git
   ```
2. Open `codexBar.xcodeproj` in Xcode 15+
3. Select your development team in **Signing & Capabilities**
4. Build and run (`⌘R`)

For local rerun during development:

```sh
scripts/restart-local.sh
```

常用参数：

```sh
scripts/restart-local.sh --config Debug   # select build configuration
scripts/restart-local.sh --build-only    # only compile, do not launch
scripts/restart-local.sh --run-only      # only relaunch app, skip compile
scripts/restart-local.sh --clean         # run `clean` before build
```

## Usage

1. Launch CodexAppBar — it appears in the menu bar
2. Click **+** to add a ChatGPT account via OAuth
3. Click **切换 / Switch** on any account to activate it; CodexAppBar will confirm and then restart Codex.app
4. The menu bar icon reflects the active account's status:
   - `terminal.fill` — normal
   - `bolt.circle.fill` — quota nearing limit (≥ 80%)
   - `exclamationmark.triangle.fill` — weekly quota exhausted
   - `xmark.circle.fill` — account suspended

## How it works

CodexAppBar uses the same OAuth client ID as the official Codex desktop app to authenticate with `auth.openai.com`. After login, tokens are stored locally in the app sandbox and the active account's tokens are written to `~/.codex/auth.json` for the Codex CLI/app to consume.

Usage data is fetched from the internal `chatgpt.com/backend-api/wham/usage` endpoint.

## Disclaimer

This project is **not affiliated with or endorsed by OpenAI**. It uses unofficial internal APIs that may change or break without notice. Use at your own risk. Do not use this tool to violate OpenAI's [Terms of Service](https://openai.com/policies/terms-of-use).

## License

[MIT](LICENSE)

---

## 中文说明

![CodexAppBar 中文](zh.png)

CodexAppBar 是一个 macOS 状态栏应用，用于管理多个 ChatGPT/Codex 账号，支持一键切换并实时监控额度。

### 功能

- **多账号管理** — 通过 OAuth 添加任意数量的 ChatGPT 账号
- **额度监控** — 实时显示 5 小时滚动窗口用量和周额度
- **账号切换**（实验性）— 将选中账号写入 `~/.codex/auth.json`，需退出 Codex.app 后生效。使用 subagent 时建议通过软件内退出登录功能切换账号
- **自动刷新** — 菜单打开时活跃账号每 10 秒刷新；后台每 5 分钟刷新所有账号
- **状态指示** — 彩色徽章和状态栏图标直观反映账号状态（正常 / 即将用尽 / 额度耗尽 / 已停用）

### 系统要求

- macOS 13 Ventura 及以上
- 已安装 [Codex](https://github.com/openai/codex) 桌面版（位于 `/Applications/Codex.app`）

### 安装

1. 克隆本仓库
2. 用 Xcode 15+ 打开 `codexBar.xcodeproj`
3. 在 **Signing & Capabilities** 中选择你的开发者账号
4. 编译运行（`⌘R`）

### 发布 Release

项目内置交互式发布脚本会自动查询上次 release、选择新 tag、archive、ad-hoc 签名、打包 zip、生成中文 release notes，并通过 GitHub CLI 创建 Release：

```sh
scripts/release.sh
```

常用参数：

```sh
scripts/release.sh --yes
scripts/release.sh --tag v2026.06.12.1
scripts/release.sh --notes-file ./release-notes.md
scripts/release.sh --dry-run
```

脚本默认要求 tracked 文件无未提交改动，避免把本地半成品误发出去；发布前请先确认 `gh auth status` 已登录。

### 免责声明

本项目**与 OpenAI 无任何关联**，使用了非官方内部 API，可能随时失效。请勿用于违反 OpenAI 服务条款的行为，风险自担。
