<p align="center">
  <img src="codexBar/Assets.xcassets/AppIcon.appiconset/icon_1024.png" alt="CodexAppBar logo" width="120">
</p>

<h1 align="center">CodexAppBar</h1>

<p align="center">
  A macOS menu bar companion for Codex users.
  <br>
  Manage accounts, monitor quota, inspect model quality, and keep local Codex usage visible.
</p>

<p align="center">
  <a href="https://github.com/iamzjt-front-end/codexbar/releases/latest">
    <img alt="Latest release" src="https://img.shields.io/github/v/release/iamzjt-front-end/codexbar?style=flat-square">
  </a>
  <a href="https://github.com/iamzjt-front-end/codexbar/stargazers">
    <img alt="GitHub stars" src="https://img.shields.io/github/stars/iamzjt-front-end/codexbar?style=flat-square">
  </a>
  <a href="https://github.com/iamzjt-front-end/codexbar/blob/main/LICENSE">
    <img alt="License" src="https://img.shields.io/github/license/iamzjt-front-end/codexbar?style=flat-square">
  </a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-15.6%2B-black?style=flat-square&logo=apple">
</p>

<p align="center">
  <a href="README.md">简体中文</a>
  ·
  <a href="README_EN.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/iamzjt-front-end/codexbar/releases/latest">Download</a>
  ·
  <a href="#features">Features</a>
  ·
  <a href="#installation">Installation</a>
  ·
  <a href="#how-it-works">How it works</a>
  ·
  <a href="#star-history">Star History</a>
</p>

> [!IMPORTANT]
> CodexAppBar is an unofficial project. It reads local Codex files and uses ChatGPT/Codex-related private endpoints that may change without notice.

## English

CodexAppBar is a macOS menu bar companion for Codex users. It brings account management, quota monitoring, Codex session status, model quality, and local token usage into a lightweight popover.

## Screenshots

<p align="center">
  <img src="en.png" alt="CodexAppBar English interface" width="420">
</p>

## Features

| Area | What it does |
| --- | --- |
| Account management | Add ChatGPT/Codex accounts through OAuth, import exported account JSON, and group Team / Workspace accounts by organization. |
| Quota monitoring | Show both 5-hour rolling quota and 7-day quota, including reset time and used / remaining display modes. |
| Menu bar status | Keep quota visible in the macOS menu bar with number mode, progress mode, and account-health colors. |
| Codex session lights | Install Codex hooks to show whether Codex is ready, running, waiting for permission, offline, or stale. |
| Model quality | Display CodexRadar Model IQ, pass count, and comparison entries from [codexradar.com](https://codexradar.com/). |
| Banked resets | Show banked Codex rate-limit reset count when the account exposes it. |
| Local token usage | Read local Codex SQLite state to show today / week / month token usage, session count, and a 16-week heatmap. |
| Global refresh | Refresh account tokens, quota usage, model quality, and local usage stats from the top-right refresh button. |
| Safer switching | Switch accounts without restarting Codex, or switch and restart Codex when you explicitly need immediate effect. |
| Localization | Switch the popover UI between Chinese and English. |

## Installation

Download the latest build from [GitHub Releases](https://github.com/iamzjt-front-end/codexbar/releases/latest).

1. Download `codexAppBar-*.zip`.
2. Unzip it and move `codexAppBar.app` to `Applications`.
3. Launch the app. It will appear in the macOS menu bar.
4. If macOS blocks the first launch, open it from Finder with right click -> Open, or allow it from System Settings.

## Requirements

- macOS 15.6 or later
- Codex desktop app installed locally
- Network access to ChatGPT/Codex endpoints for quota and account metadata
- Optional: Codex hooks enabled for session-status lights

## Build From Source

```sh
git clone https://github.com/iamzjt-front-end/codexbar.git
cd codexbar
open codexBar.xcodeproj
```

Build and run the `codexBar` scheme from Xcode, or use the local restart script:

```sh
scripts/restart-local.sh
```

Useful flags:

```sh
scripts/restart-local.sh --config Debug
scripts/restart-local.sh --build-only
scripts/restart-local.sh --run-only
scripts/restart-local.sh --clean
```

## Usage

1. Open CodexAppBar from the macOS menu bar.
2. Add an account with OAuth, or import an exported account JSON.
3. Install hooks if you want Codex session lights in the menu bar.
4. Use the bottom controls to adjust refresh interval, quota display mode, menu bar display mode, session lights, and language.
5. When switching accounts, choose one of the two modes:
   - Switch only: update `~/.codex/auth.json` without restarting Codex.
   - Switch and restart: update the account and restart Codex immediately.

## How It Works

CodexAppBar does not require a hosted backend. It combines local Codex files with OpenAI / Codex-related endpoints.

| Data | Source |
| --- | --- |
| Account pool | `~/.codex/token_pool.json` |
| Active account | `~/.codex/auth.json` |
| Quota usage | `https://chatgpt.com/backend-api/wham/usage` |
| Account / organization metadata | `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27` |
| Model quality | `https://codexradar.com/current.json` |
| Local token usage | `~/.codex/sqlite/state_5.sqlite` or `~/.codex/state_5.sqlite` |
| Hook configuration | `~/.codex/hooks.json` |
| Session status hook | `~/.codex/codexbar/codexbar-session-status-hook.py` |
| Session status output | `~/.codex/codexbar/session_status.json` |

## Privacy And Safety

CodexAppBar is designed to run locally, but it touches sensitive Codex authentication state.

- OAuth tokens and account exports should stay on your own machine.
- Do not commit or share `token_pool.json`, `auth.json`, or exported account JSON.
- Account switching writes to `~/.codex/auth.json`.
- Hook installation backs up and updates `~/.codex/hooks.json`.
- Restarting Codex can interrupt running tasks.
- Private endpoints and local file formats may change at any time.

## Release

The repository includes a release helper that creates release notes, archives the app, applies ad-hoc signing, packages a zip, and publishes with GitHub CLI.

```sh
scripts/release.sh
```

Common flags:

```sh
scripts/release.sh --yes
scripts/release.sh --tag v2026.06.15
scripts/release.sh --notes-file ./release-notes.md
scripts/release.sh --dry-run
scripts/release.sh --allow-dirty
```

Before publishing, make sure `gh auth status` is valid, the target tag does not already exist, and the working tree contains only intentional changes.

## Star History

<a href="https://www.star-history.com/#iamzjt-front-end/codexbar&Date">
  <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=iamzjt-front-end/codexbar&type=Date">
</a>

## Acknowledgements

- Model quality data is provided by [CodexRadar](https://codexradar.com/).
- This project follows the local Codex file layout and may need updates when Codex changes its internal formats.

## License

[MIT](LICENSE)
