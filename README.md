# 💳 SeekBalance

一个 macOS 菜单栏小工具：一眼看到 DeepSeek API 的**余额**、**今日用量**和**花费估算**。

> 本项目由作者提出需求、使用 AI 辅助编写代码。

![Platform](https://img.shields.io/badge/macOS-13%2B-blue) ![License](https://img.shields.io/badge/License-MIT-green) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) [![Download](https://img.shields.io/badge/下载-最新版-brightgreen)](https://github.com/VincentPhoton/SeekBalance/releases/latest)

**简体中文** · [English](README.en.md)

---

## 它有什么用？

- 菜单栏常驻显示余额（如 `¥7.85`），不占 Dock，不弹窗打扰
- 点击图标弹出面板：余额 / 充值 / 赠送、今日请求次数与 token、累计用量与花费
- 自动刷新频率可选（3 / 5 / 10 分钟，默认 5）；打开面板立即刷新
- 完美适配**浅色 / 深色模式**（明暗两套配色，自动跟随系统），实心背景高对比度，小屏幕也一屏放下

## 截图

菜单栏显示余额，点击弹出面板，自动适配浅色 / 深色模式（点击图片可看大图）：

| 浅色模式 | 暗色模式 |
| :---: | :---: |
| ![浅色模式](screenshots/light-mode.png) | ![暗色模式](screenshots/dark-mode.png) |

## 功能细节

- **首次使用**：面板内直接粘贴 DeepSeek API 密钥，自动存入 Mac 钥匙串（无需配置文件）
- **花费精确计价**：完全适配 DeepSeek 最新峰谷价格梯度（高峰 9:00–12:00、14:00–18:00 / 空闲价），按每次请求的实际时间精确估算——配合时段提示与高峰前提醒，帮你避开高峰、在空闲时段用 API，更省钱
- **高峰/空闲用量分开统计**：今日用量分别显示高峰时段与空闲时段的 token 用量
- **时段状态提示**：面板显示当前是高峰还是空闲时段（含时间段），并倒计时距**当前时段结束**还有多久
- **高峰前提醒**：可设置提前 0–60 分钟发系统通知，提醒"高峰快到了、价格将上调"（仅空闲时段提醒，同一波高峰只提醒一次）
- 菜单栏余额文字可开关（面板内"状态栏显示余额"）
- 自动刷新间隔可选（3 / 5 / 10 分钟，默认 5）
- 自检模式：`./.build/release/SeekBalance --once` 打印报告后退出

## 安装

### 方式一：DMG 安装包（推荐，Apple 芯片专用）

> ⚠️ 仅支持 **Apple 芯片**（M1 / M2 / M3 / M4，arm64）。Intel Mac 暂不支持。

1. 直接下载：[**SeekBalance-1.1.2-arm64.dmg**](https://github.com/VincentPhoton/SeekBalance/releases/latest/download/SeekBalance-1.1.2-arm64.dmg)（或到 [Releases](../../releases) 页面下载）
2. 打开 DMG，把 `SeekBalance.app` 拖进"应用程序"
3. 首次打开若提示"无法验证开发者"：右键 → 打开 → 再点"打开"
4. DMG 里附带了"卸载SeekBalance"一键卸载程序（自动清理偏好与缓存）

### 方式二：源码编译

需要 macOS 13+ 和 Swift 5.9+：

```sh
cd SeekBalance
SWIFTPM_CACHE_DIR=/tmp/swiftpm-cache swift build -c release
# 自检（打印一次报告后退出）：
./.build/release/SeekBalance --once
```

## 使用前提

| 依赖 | 说明 |
|---|---|
| API 密钥 | **两种方式任选**：① 打开软件，在面板里直接粘贴密钥（自动存入 Mac 钥匙串，系统加密）；② 或创建配置文件 `~/.dsh/.credentials.yaml`，写入一行 `DEEPSEEK_API_KEY: 你的密钥`（dsh 用户已有此文件，直接用）。密钥只用于请求 DeepSeek 官方接口 |
| zstd | 用于解压 dsh 会话日志。`brew install zstd`（Apple Silicon 在 `/opt/homebrew/bin/zstd`，Intel 在 `/usr/local/bin/zstd`，自动识别） |
| dsh 会话记录（可选） | 有 dsh 用量统计；没有则"今日/累计用量"显示为空，仅余额可用 |

## 数据来源与安全说明

| 数据 | 来源 | 范围 |
|---|---|---|
| 余额 | `GET https://api.deepseek.com/user/balance`（Bearer 认证） | **全账户**，实时准确 |
| 今日用量 | 本机 `~/.dsh/sessions/*/*/session.jsonl.zstd` 会话日志 | **仅本机** |
| 累计用量 | 本机 `~/.dsh/storages/session_projcache.json` | **仅本机** |
| 花费 | 按**每次请求的实际时间**精确计价，适配最新峰谷价格（高峰 9:00–12:00、14:00–18:00 / 空闲价） | **仅本机，非官方账单** |

- 你的 API 密钥**只用于**请求 DeepSeek 官方接口（`api.deepseek.com`），不会发送到任何第三方
- 本工具**不联网上传任何统计数据**，所有用量数据都来自你本地的 dsh 文件
- DeepSeek **未提供公开的用量查询接口**（实测 `/user/usage` 等均返回 404），因此用量统计只能读取本机记录；全账户用量需网页后台私有接口，未采用

## 卸载

- 用安装包内附的"卸载SeekBalance"一键卸载，或手动删除 `/Applications/SeekBalance.app`
- 手动卸载残留：`~/Library/Preferences/local.seekbalance.plist`、`~/Library/Caches/local.seekbalance/` 等
- 卸载不会删除 `~/.dsh/` 数据（与 dsh 共用，请放心）

## 开发者

- 编译：`swift build -c release`
- 打 DMG：`hdiutil create -volname "SeekBalance" -srcfolder dmg-build -ov -format UDZO -fs HFS+ "SeekBalance-1.1.2-arm64.dmg"`（`dmg-build/` 内放入 `.app`、Applications 快捷方式、卸载程序与安装说明）

## License

[MIT](LICENSE)

## 免责声明

本项目与 DeepSeek 官方无任何关联，为第三方社区工具。花费估算仅供参考，实际扣费请以 DeepSeek 官方账单为准。
