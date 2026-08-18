# SeekBalance

> [English](README.en.md) · 简体中文

<p align="center">
  <img src="docs/icon.png" width="120" alt="SeekBalance 图标">
</p>

<p align="center">
  <strong>一眼看到 DeepSeek 的余额与用量。</strong>
</p>

<p align="center">
  SeekBalance 是一款 macOS 菜单栏小工具：余额、今日用量、花费估算，实时可见；还能提醒你避开高峰时段、更省钱地用 API。
</p>

<p align="center">
  <a href="https://github.com/VincentPhoton/SeekBalance/releases/latest"><strong>下载最新版</strong></a> ·
  <a href="#功能亮点">功能亮点</a> ·
  <a href="#截图">截图</a> ·
  <a href="#安装">安装</a> ·
  <a href="#使用前提">使用前提</a> ·
  <a href="#数据来源与安全说明">数据安全</a> ·
  <a href="#卸载">卸载</a>
</p>

<p align="center">
  <a href="https://github.com/VincentPhoton/SeekBalance/releases/latest">
    <img alt="从 GitHub 免费下载" src="https://img.shields.io/badge/GitHub-%E5%85%8D%E8%B4%B9%E4%B8%8B%E8%BD%BD-2ECC71?style=for-the-badge&logo=github&logoColor=white" height="42">
  </a>
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-111827?style=flat-square&logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-M%20series-2ECC71?style=flat-square&logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green?style=flat-square">
</p>

## 截图

自动适配浅色 / 深色模式（点击图片可看大图）：

| 浅色模式 | 暗色模式 |
| :---: | :---: |
| ![浅色模式](screenshots/light-mode.png) | ![暗色模式](screenshots/dark-mode.png) |

## 功能亮点

### 菜单栏一眼可见

菜单栏常驻显示余额（如 `¥7.85`），不占 Dock、不弹窗打扰；余额文字可随时开关。**左键**弹出完整面板，**右键**弹出快捷菜单（刷新 / 检查更新 / 关于 / GitHub / 退出）。

### 时段状态与省钱提醒

- **当前时段一目了然**：面板显示现在是高峰还是空闲（含时间段），并倒计时距当前时段结束还有多久；空闲剩 ≤30 分钟时倒计时变红提醒你"抓紧用"
- **高峰前提醒**：可设置提前 0–60 分钟发系统通知——"高峰快到了，价格将上调"
- **花费精确计价**：完全适配 DeepSeek 最新峰谷价格梯度（高峰 9:00–12:00、14:00–18:00 / 空闲价），按每次请求的实际时间精确估算

### 用量与花费统计

- **今日用量**：请求次数、输入（未命中 + 缓存）、输出，并**分开统计高峰 / 空闲时段的用量**
- **累计用量与花费**：输入 / 输出 / 精确花费估算
- **自动刷新**：频率可选（3 / 5 / 10 分钟，默认 5），打开面板立即刷新

### 首次使用很简单

打开软件，在面板里**直接粘贴 DeepSeek API 密钥**即可——自动存入 Mac 钥匙串（系统加密），无需任何配置文件（dsh 用户可直接用现有配置）。

### 检查更新

面板或右键菜单点"检查更新"：自动对比 GitHub 最新版本，有新版则**自动下载、安装并重启**；已是最新版会弹窗提示（含上次检查时间）。

## 安装

1. 从 [Releases](https://github.com/VincentPhoton/SeekBalance/releases/latest) 下载最新版 `SeekBalance-1.1.4-arm64.dmg`
2. 打开 DMG，把 `SeekBalance.app` 拖入"应用程序"
3. 首次打开若提示"无法验证开发者"：右键 → 打开 → 再点"打开"
4. DMG 内附带"卸载SeekBalance"一键卸载程序

### 源码编译

需要 macOS 13+ 和 Swift 5.9+：

```sh
cd SeekBalance
SWIFTPM_CACHE_DIR=/tmp/swiftpm-cache swift build -c release
# 自检（打印一次报告后退出）：
./.build/release/SeekBalance --once
```

## 系统要求

- macOS 13+
- Apple 芯片（M1 / M2 / M3 / M4，arm64）
- [zstd](https://github.com/facebook/zstd)（`brew install zstd`，用于解压 dsh 会话日志，自动识别安装位置）

## 使用前提

| 依赖 | 说明 |
|---|---|
| API 密钥 | 两种方式任选：① 打开软件，在面板里直接粘贴密钥（自动存入 Mac 钥匙串，系统加密）；② 或创建配置文件 `~/.dsh/.credentials.yaml`，写入一行 `DEEPSEEK_API_KEY: 你的密钥`（dsh 用户已有此文件，直接用）。密钥只用于请求 DeepSeek 官方接口 |
| dsh 会话记录（可选） | 有 dsh 则显示今日/累计用量统计；没有则用量为空，仅余额可用 |

## 数据来源与安全说明

| 数据 | 来源 | 范围 |
|---|---|---|
| 余额 | `GET https://api.deepseek.com/user/balance`（Bearer 认证） | **全账户**，实时准确 |
| 今日用量 | 本机 `~/.dsh/sessions/*/*/session.jsonl.zstd` 会话日志 | **仅本机** |
| 累计用量 | 本机 `~/.dsh/storages/session_projcache.json` | **仅本机** |
| 花费 | 按**每次请求的实际时间**精确计价，适配最新峰谷价格 | **仅本机，非官方账单** |

- 你的 API 密钥**只用于**请求 DeepSeek 官方接口（`api.deepseek.com`），不会发送到任何第三方
- 本工具**不联网上传任何统计数据**，所有用量数据都来自你本地的 dsh 文件
- DeepSeek **未提供公开的用量查询接口**（实测 `/user/usage` 等均返回 404），因此用量统计只能读取本机记录

## 卸载

- 用安装包内附的"卸载SeekBalance"一键卸载，或手动删除 `/Applications/SeekBalance.app`
- 手动卸载残留：`~/Library/Preferences/local.seekbalance.plist`、`~/Library/Caches/local.seekbalance/` 等
- 卸载不会删除 `~/.dsh/` 数据（与 dsh 共用，请放心）

## 构建

- 编译：`swift build -c release`
- 打 DMG：`hdiutil create -volname "SeekBalance" -srcfolder dmg-build -ov -format UDZO -fs HFS+ "SeekBalance-1.1.4-arm64.dmg"`（`dmg-build/` 内放入 `.app`、Applications 快捷方式、卸载程序与安装说明）

## License

[MIT](LICENSE)

## 免责声明

本项目与 DeepSeek 官方无任何关联，为第三方社区工具。花费估算仅供参考，实际扣费请以 DeepSeek 官方账单为准。
