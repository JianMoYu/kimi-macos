# Kimi Code for macOS

<p align="center">
  <img src="Resources/AppIcon.png" width="96" height="96" alt="Kimi Code macOS Icon" />
</p>

专为 Kimi Code (`kimi web`) 打造的 macOS 原生桌面客户端，基于 Swift + WebKit 开发。

---

## 核心亮点

- **⚡️ 纯原生轻量**：无 Electron 冗余依赖，二进制体积仅约 1 MB，内存开销小，毫秒级启动与流畅渲染。
- **📊 顶部常驻 Token 统计**：顶部原生工具栏常驻展示「当前会话」与「今日全天」Token 消耗及缓存命中率（🎯 Cache%），不遮挡页面内容、无需点击即可掌握；点击可展开未缓存输入、缓存输入、输出明细。
- **🤖 Agent 实时遥测与监视**：原生捕获 WebSocket 数据流，实时感知 Token 生成速度（tok/s）、上下文占用及 SubAgent 并行状态；当 Agent 需要权限确认时自动发送系统级弹窗通知。
- **🔋 套餐用量直观感知**：工具栏胶囊直接展示周限额与 5 小时限额迷你进度条，用量超 80%/95% 时主动预警，避免额度意外耗尽。
- **🛡️ 后台进程守护与无感登录**：启动自动通过 tmux 守护 `kimi web`，关闭窗口任务不中断；自动注入本地凭证，免去手动输入 Token。

---

## 前置要求

- macOS 13.0+
- [Kimi CLI](https://github.com/MoonshotAI/kimi-code)（已安装 `kimi` 命令）
- `tmux`（用于后台进程守护：`brew install tmux`）

---

## 构建与安装

```bash
git clone https://github.com/JianMoYu/kimi-macos.git
cd kimi-macos

# 编译生成 Kimi.app
./scripts/build.sh

# 打包 DMG 安装镜像
./scripts/package_dmg.sh
```

构建产物位于 `dist/` 目录：
- `dist/Kimi.app`
- `dist/Kimi-Installer-arm64.dmg`

---

## 常用快捷键

| 快捷键 | 说明 |
| :--- | :--- |
| `Cmd + R` | 刷新页面与用量 |
| `Cmd + Shift + R` | 重启后台 Kimi 服务 |
| `Cmd + W` | 关闭窗口（后台任务与 tmux 会话继续执行） |
| `Cmd + Q` | 退出 App（保留后台服务） |

---

## 故障排查

- **提示「服务暂未响应」**：
  确认 `kimi --version` 可用且已安装 `tmux`。App 会在错误页提供自动重试。
- **页面 404 或资源异常**：
  多因 kimi CLI 更新导致前端缓存损坏，点击错误页的「一键修复」按钮，或手动清理：
  ```bash
  rm -rf ~/Library/Caches/kimi-code/web
  tmux kill-session -t kimi-web
  ```

---

## 开源协议

[MIT License](LICENSE)
