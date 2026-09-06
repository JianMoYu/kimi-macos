# Kimi Code for macOS

<p align="center">
  <img src="Resources/AppIcon.png" width="100" height="100" alt="Kimi Code macOS Icon" />
</p>

专为 Kimi Code (`kimi web`) 封装的 macOS 原生客户端，基于 SwiftUI 与 WebKit 构建。

---

## 功能

- **后台常驻与服务自启**：打开 App 自动检测本地 `58627` 端口，未启动时自动通过 `tmux` 拉起后台服务；关闭 App 时保留服务继续运行。
- **菜单栏常驻用量**：菜单栏显示 App 图标与 5 小时用量百分比（阈值红黄绿着色），点开即可唤起窗口、重载页面、重启服务、attach tmux。
- **顶部显示套餐用量**：工具栏以迷你进度条展示每周限额与 5 小时限额，点击弹出详情（精确用量、重置倒计时、用量走势图）。仅在前台活跃时刷新，窗口隐藏时暂停轮询。
- **配额预警与任务完成通知**：用量越过 80% / 95% 阈值或配额重置时发送本地通知；内嵌页面调用系统 Notification API（任务完成提醒）时自动授权并转发为本地通知。首次启动会请求通知权限，拒绝后预警静默失效（可到系统设置重新开启）。
- **最近工作目录**：工具栏目录下拉直接切换最近 5 个项目，无需反复打开选择框。
- **免密自动登录**：默认开启 `--dangerous-bypass-auth` 并自动读取本地 Token，无需手动输入。
- **外观跟随系统**：窗口与加载底色随系统深浅色自适应，内嵌 Web UI 主题由其自身设置（跟随系统/浅色/深色）控制。
- **环境体检与一键修复**：启动超时自动诊断 kimi CLI / tmux 缺失并给出安装指引；Web UI 缓存损坏时提供「一键修复」按钮。
- **轻量原生**：无 Electron 依赖，打包体积约 800 KB。

---

## 前置要求

- macOS 13.0+
- [Kimi CLI](https://github.com/MoonshotAI/kimi-code)：已安装且可执行 `kimi` 命令
- `tmux`：用于后台会话守护 (`brew install tmux`)
- Xcode Command Line Tools（仅源码构建需要）

---

## 构建与运行

```bash
git clone https://github.com/JianMoYu/kimi-macos.git
cd kimi-macos

# 编译生成 Kimi.app
./scripts/build.sh

# 或一键生成 DMG 安装包
./scripts/package_dmg.sh
```

构建产物位于 `dist/` 目录：
- `dist/Kimi.app`
- `dist/Kimi-Installer-arm64.dmg`

---

## 快捷键

| 快捷键 | 说明 |
| :--- | :--- |
| `Cmd + R` | 刷新页面与用量 |
| `Cmd + Shift + R` | 重启后台 Kimi 服务 |
| `Cmd + W` | 隐藏窗口（后台任务继续执行，菜单栏图标仍在） |
| `Cmd + Q` | 退出 App（后台服务保留） |

---

## 故障排查

### 显示「服务暂未响应」

App 健康检查分两级：先探测 `/api/v1/meta`（后端就绪信号），再探测 `/`（Web UI 资源）。

- **后端超时**：确认 `kimi --version` 可用、`tmux` 已安装。App 会在错误页每 10 秒自动重试。
- **后端正常但 Web UI 资源 404**：kimi CLI 的 SPA bundle 解压失败（上游缓存损坏，多见于 kimi 版本升级后）。App 会自动重启服务尝试重建资源一次；若未恢复，错误页会出现「一键修复（清理缓存重建）」按钮，点击即可自动完成清理并重启服务。也可手动执行后点击「重新连接」：

  ```bash
  rm -rf ~/Library/Caches/kimi-code/web
  tmux kill-session -t kimi-web   # 重启后 kimi web 会重新解压资源
  ```

### 手动重启后台服务

```bash
tmux kill-session -t kimi-web
# 然后在 App 中点击「重启服务」或「重新连接」
```

---

## 开源协议

[MIT License](LICENSE)
