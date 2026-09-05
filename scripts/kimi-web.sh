#!/usr/bin/env bash

set -euo pipefail

SESSION_NAME="${KIMI_TMUX_SESSION:-kimi-web}"
PORT="${KIMI_WEB_PORT:-58627}"
WORK_DIR="${KIMI_WORK_DIR:-$(pwd)}"
KIMI_BIN="${KIMI_BIN:-$(command -v kimi 2>/dev/null || true)}"

if [ -z "$KIMI_BIN" ] || [ ! -x "$KIMI_BIN" ]; then
    if [ -x "$HOME/.kimi-code/bin/kimi" ]; then
        KIMI_BIN="$HOME/.kimi-code/bin/kimi"
    fi
fi

usage() {
    cat <<'EOF'
用法：
  ./kimi-web.sh start       后台启动 Kimi Web（默认）
  ./kimi-web.sh attach      进入 tmux 会话
  ./kimi-web.sh status      查看运行状态
  ./kimi-web.sh restart     重启 Kimi Web
  ./kimi-web.sh stop        停止 Kimi Web

可选环境变量：
  KIMI_WEB_PORT       Web 端口，默认 58627
  KIMI_WORK_DIR       Kimi 工作目录，默认当前目录
  KIMI_TMUX_SESSION   tmux 会话名，默认 kimi-web
  KIMI_BIN            kimi 可执行文件路径
EOF
}

require_tmux() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo "错误：未找到 tmux，请先通过 brew install tmux 安装。" >&2
        exit 1
    fi
}

is_running() {
    tmux has-session -t "$SESSION_NAME" 2>/dev/null
}

start() {
    require_tmux

    if [ -z "$KIMI_BIN" ] || [ ! -x "$KIMI_BIN" ]; then
        echo "错误：未找到可执行的 kimi 命令。" >&2
        echo "可通过 export KIMI_BIN=/完整路径/kimi 指定，或确保 ~/.kimi-code/bin 在 PATH 中。" >&2
        exit 1
    fi

    case "$PORT" in
        ''|*[!0-9]*)
            echo "错误：KIMI_WEB_PORT 必须是数字。" >&2
            exit 1
            ;;
    esac

    if [ ! -d "$WORK_DIR" ]; then
        echo "错误：工作目录不存在：$WORK_DIR" >&2
        exit 1
    fi

    if is_running; then
        echo "Kimi Web 已在运行：tmux 会话 $SESSION_NAME"
        echo "进入会话：$0 attach"
        return
    fi

    tmux new-session -d \
        -s "$SESSION_NAME" \
        -c "$WORK_DIR" \
        "$KIMI_BIN web --port $PORT --no-open --dangerous-bypass-auth"

    echo "Kimi Web 已启动。"
    echo "地址：http://127.0.0.1:$PORT"
    echo "工作目录：$WORK_DIR"
    echo "进入会话：$0 attach"
}

attach() {
    require_tmux
    if ! is_running; then
        echo "Kimi Web 未运行，请先执行：$0 start" >&2
        exit 1
    fi
    exec tmux attach-session -t "$SESSION_NAME"
}

status() {
    require_tmux
    if is_running; then
        echo "Kimi Web 正在运行：tmux 会话 $SESSION_NAME"
        echo "地址：http://127.0.0.1:$PORT"
    else
        echo "Kimi Web 未运行。"
        exit 1
    fi
}

stop() {
    require_tmux
    if is_running; then
        tmux kill-session -t "$SESSION_NAME"
        echo "Kimi Web 已停止。"
    else
        echo "Kimi Web 未运行。"
    fi
}

ACTION="${1:-start}"

case "$ACTION" in
    start)   start ;;
    attach)  attach ;;
    status)  status ;;
    restart) stop; start ;;
    stop)    stop ;;
    help|-h|--help) usage ;;
    *)
        echo "错误：未知操作：$ACTION" >&2
        usage >&2
        exit 2
        ;;
esac
