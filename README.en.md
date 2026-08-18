# 💳 SeekBalance

A macOS menu bar utility: see your DeepSeek API **balance**, **today's usage**, and **cost estimates** at a glance.

> This project was built from the author's own idea, with AI-assisted coding.

![Platform](https://img.shields.io/badge/macOS-13%2B-blue) ![License](https://img.shields.io/badge/License-MIT-green) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) [![Download](https://img.shields.io/badge/Download-Latest-brightgreen)](https://github.com/VincentPhoton/SeekBalance/releases/latest)

[简体中文](README.md) · **English**

---

## Highlights

- Menu bar balance display (e.g., `¥7.85`) — no Dock icon, no popups
- Click the icon to open a panel: balance / top-up / granted, today's request count & tokens, cumulative usage & cost
- Auto-refresh interval selectable (3 / 5 / 10 minutes, default 5); refreshes instantly when the panel opens
- Fully supports **light / dark mode** (two color schemes, follows the system), solid background with high contrast, fits small screens without scrolling

## Screenshots

Click the icon to open the panel — automatically adapts to light / dark mode (click for full size):

| Light mode | Dark mode |
| :---: | :---: |
| ![Light mode](screenshots/light-mode.png) | ![Dark mode](screenshots/dark-mode.png) |

## Feature details

- **Paste your API key right in the panel** on first use — securely stored in the macOS Keychain (no config file needed)
- **Precise cost calculation**: fully supports DeepSeek's latest peak/off-peak pricing (peak 9:00–12:00, 14:00–18:00 Beijing time; off-peak otherwise), estimating each request by its actual time — combined with the period indicator and peak reminders, it helps you avoid peak hours, use the API during off-peak periods, and save money
- **Peak/off-peak usage split**: today's usage shows tokens consumed during peak and off-peak periods separately
- **Period status indicator**: the panel shows whether it is currently peak or off-peak (with the time range) and counts down to the end of the current period
- **Peak reminders**: schedule a system notification 0–60 minutes before the peak starts ("peak is coming, prices will go up") — only during off-peak periods, once per peak window
- Menu bar balance text can be toggled on/off ("Show balance in menu bar" in the panel)
- Auto-refresh interval selectable (3 / 5 / 10 minutes, default 5)
- **Right-click menu on the menu bar icon**: Refresh / Check for updates / About (name, version, what it does, author) / GitHub page / Quit
- Self-check mode: `./.build/release/SeekBalance --once` prints a report and exits

## Installation

### Option 1: DMG installer (recommended, Apple Silicon)

> ⚠️ Requires **Apple Silicon** (M1 / M2 / M3 / M4, arm64). Intel Macs are not supported.

1. Download directly: [**SeekBalance-1.1.3-arm64.dmg**](https://github.com/VincentPhoton/SeekBalance/releases/latest/download/SeekBalance-1.1.3-arm64.dmg) (or from the [Releases](../../releases) page)
2. Open the DMG and drag `SeekBalance.app` into "Applications"
3. If macOS says "cannot verify the developer" on first launch: right-click → Open → Open again
4. The DMG includes the "UninstallSeekBalance" one-click uninstaller (cleans preferences & caches)

### Option 2: Build from source

Requires macOS 13+ and Swift 5.9+:

```sh
cd SeekBalance
SWIFTPM_CACHE_DIR=/tmp/swiftpm-cache swift build -c release
# Self-check (prints a report and exits):
./.build/release/SeekBalance --once
```

## Prerequisites

| Dependency | Description |
|---|---|
| API key | Either way works: ① open the app and paste the key in the panel (stored in the macOS Keychain, system-encrypted); ② or create a config file `~/.dsh/.credentials.yaml` with one line: `DEEPSEEK_API_KEY: your-key` (dsh users already have this file). The key is only used to call DeepSeek's official API |
| zstd | Used to decompress dsh session logs. `brew install zstd` (auto-detected at `/opt/homebrew/bin/zstd` on Apple Silicon, `/usr/local/bin/zstd` on Intel) |
| dsh session logs (optional) | With dsh you get usage stats; without it, "Today/Cumulative usage" stays empty and only the balance is available |

## Data sources & security

| Data | Source | Scope |
|---|---|---|
| Balance | `GET https://api.deepseek.com/user/balance` (Bearer auth) | **Whole account**, real-time & accurate |
| Today's usage | Local `~/.dsh/sessions/*/*/session.jsonl.zstd` session logs | **This machine only** |
| Cumulative usage | Local `~/.dsh/storages/session_projcache.json` | **This machine only** |
| Cost | Precise estimate per request by actual time, adapting to the latest peak/off-peak pricing (peak 9:00–12:00, 14:00–18:00 / off-peak) | **This machine only, not an official bill** |

- Your API key is **only** used to request DeepSeek's official endpoint (`api.deepseek.com`) and is never sent to any third party
- This tool **does not upload any statistics**; all usage data comes from your local dsh files
- DeepSeek does **not provide a public usage-query API** (tested `/user/usage` etc. all return 404), so usage stats can only be read from local records; account-wide usage would require private dashboard endpoints, which are not used

## Uninstall

- Use the built-in "UninstallSeekBalance" one-click uninstaller in the DMG, or manually delete `/Applications/SeekBalance.app`
- Manual leftovers: `~/Library/Preferences/local.seekbalance.plist`, `~/Library/Caches/local.seekbalance/`, etc.
- Uninstalling does **not** delete `~/.dsh/` data (shared with dsh)

## For developers

- Build: `swift build -c release`
- Create DMG: `hdiutil create -volname "SeekBalance" -srcfolder dmg-build -ov -format UDZO -fs HFS+ "SeekBalance-1.1.3-arm64.dmg"` (put the `.app`, an Applications shortcut, the uninstaller, and install notes into `dmg-build/`)

## License

[MIT](LICENSE)

## Disclaimer

This project is not affiliated with DeepSeek; it is a third-party community tool. Cost estimates are for reference only; actual charges are subject to DeepSeek's official billing.
