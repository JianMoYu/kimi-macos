# Kimi Code for macOS

<p align="center">
  <img src="Resources/AppIcon.icns" width="128" height="128" alt="Kimi Code macOS Icon" />
</p>

<p align="center">
  <strong>专为 Kimi Code 打造的轻量原生 macOS 客户端</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2013.0+-blue?logo=apple" alt="macOS" />
  <img src="https://img.shields.io/badge/Language-SwiftUI%20%7C%20WebKit-F05138?logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/Bundle%20Size-＜%201%20MB-success" alt="Bundle Size" />
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License" />
</p>

---

## 📖 项目简介

很多开发者在本地使用 Kimi Code 时，经常遇到以下痛点：
1. 每次都需要打开终端手动敲命令启动服务（`kimi web`）；
2. 浏览器打开后混杂在数十个标签页中，容易被误关或难以快速定位；
3. 想要了解套餐用量需要每次层层点击进入「头像 -> 设置 -> 账户」；
4. 退出浏览器或终端断开后，正在运行的长时间 Agent 任务容易中断。

**Kimi Code macOS Client** 采用纯原生 **SwiftUI + WebKit** 构建，为 Kimi Code 提供独立的系统窗口、专属 Dock 图标、后台服务守护与实时用量看板，打造极致丝滑的本地编码体验。

---

## ✨ 核心特性

- ⚡️ **极致原生轻量**：无任何 Electron 冗余，打包体积仅约 **800 KB**，内存占用低，启动极快。
- 📊 **顶部实时用量看板**：直接在顶部工具栏居中展示**每周限额**与**5小时限额**已用百分比及重置倒计时；超过 90% 智能标红预警，无需进入设置。
- 🍃 **智能按需轮询（节能）**：仅在用户前台使用时每 30 秒自动同步；当窗口隐藏、最小化时**立刻销毁轮询定时器**，实现零后台网络 IO 与零 CPU 开销。
- 🚀 **后台服务自动拉起与守护**：启动 App 时并发检测本地端口（默认 `58627`），未运行时自动通过 `tmux` 静默拉起；关闭窗口后后台服务继续常驻。
- 🛑 **0.0 秒瞬间唤起（Agent 任务不中断）**：点击左上角红叉「X」仅隐藏窗口而不销毁，内存保持常驻，长时间 Agent 任务输出永不中断；点击 Dock 图标 0 延迟秒开，彻底告别白屏重载。
- 🔑 **全自动免密与 Token 注入**：内置本地免密模式（`--dangerous-bypass-auth`），并提供持久化 Token 自动读取机制，绝不弹出“需要服务器 token”弹窗。
- 📁 **工作目录便捷切换**：顶部一键选择本地项目目录，自动记忆并在切换时提示重启生效。
- 🔄 **无缝版本升级**：Kimi Code 更新后，点击顶部「重启服务」即可无缝切换至最新的 Kimi 二进制与 Web 前端。

---

## 🛠 前置要求

在构建或运行前，请确保本地已安装以下组件：

1. **Kimi CLI**：
   ```bash
   which kimi
   # 确保已安装官方 kimi 命令行工具
   ```
2. **tmux**（用于后台会话守护）：
   ```bash
   brew install tmux
   ```
3. **Xcode Command Line Tools**：
   ```bash
   xcode-select --install
   ```

---

## 🚀 快速开始

克隆仓库到本地自行构建或按需修改：

```bash
git clone https://github.com/your-username/kimi-macos.git
cd kimi-macos

# 编译生成 Kimi.app
./scripts/build.sh

# 或一键生成 DMG 安装包
./scripts/package_dmg.sh
```

构建完成后，产物位于 `dist/` 目录：
- `dist/Kimi.app`：可以直接双击运行，或拖入 `/Applications`
- `dist/Kimi-Installer-arm64.dmg`：可分发安装镜像

---

## 📂 项目结构

```
kimi-macos/
├── Sources/
│   ├── App.swift                 # 应用程序入口、单实例窗口及尺寸持久化
│   ├── ContentView.swift         # 顶部工具栏、用量监控看板及 UI 交互
│   ├── KimiServiceManager.swift  # tmux 会话调度、端口健康检查与智能轮询
│   └── WebView.swift             # WKWebView 封装、暗黑底色及鉴权脚本注入
├── Resources/
│   ├── AppIcon.icns              # 高清 App 图标
│   └── Info.plist                # 应用配置清单
├── scripts/
│   ├── build.sh                  # 自动化编译脚本
│   ├── package_dmg.sh            # DMG 镜像打包脚本
│   └── kimi-web.sh               # 独立的后台启动与守护 shell 脚本
├── .gitignore
├── LICENSE                       # MIT 许可证
└── README.md
```

---

## ⌨️ 常用快捷键

| 快捷键 | 功能描述 |
| :--- | :--- |
| `Cmd + R` | 刷新 Web 页面并立即同步用量数据 |
| `Cmd + Shift + R` | 重启后台 Kimi 服务（加载最新更新） |
| `Cmd + W` | 隐藏当前窗口（保持后台常驻，不中断任务） |
| `Cmd + Q` | 退出 App（后台 tmux 服务仍将保持运行） |

---

## 📄 开源许可

本项目基于 [MIT License](LICENSE) 开源。
