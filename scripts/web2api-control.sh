#!/data/data/com.termux/files/usr/bin/bash
# Termux controller for the separate Gemini Web2API installation.
set -u
API_DIR="${GEMINI_WEB2API_DIR:-$HOME/gemini-web2api}"
API_FILE="${GEMINI_WEB2API_FILE:-$API_DIR/gemini_web2api.py}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/jarvis"
PID_FILE="$STATE_DIR/web2api.pid"
LOG_FILE="$STATE_DIR/web2api.log"
mkdir -p "$STATE_DIR"
is_running() {
  [ -s "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fq gemini_web2api.py
}
start_server() {
  if is_running; then echo "Web2API already running (PID $(cat "$PID_FILE"))."; return 0; fi
  rm -f "$PID_FILE"
  [ -f "$API_FILE" ] || { echo "Web2API script not found: $API_FILE" >&2; return 1; }
  command -v python >/dev/null 2>&1 || { echo "Python is unavailable." >&2; return 1; }
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock >/dev/null 2>&1 || true
  cd "$API_DIR" || return 1
  nohup python "$API_FILE" >> "$LOG_FILE" 2>&1 < /dev/null &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then echo "Web2API started (PID $pid). Log: $LOG_FILE"; else rm -f "$PID_FILE"; tail -40 "$LOG_FILE" 2>/dev/null || true; return 1; fi
}
stop_server() {
  if ! is_running; then rm -f "$PID_FILE"; echo "Web2API is not running under this controller."; return 0; fi
  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then echo "Server did not stop gracefully; leaving it running." >&2; return 1; fi
  rm -f "$PID_FILE"
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock >/dev/null 2>&1 || true
  echo "Web2API stopped."
}
case "${1:-status}" in
  start) start_server ;;
  stop) stop_server ;;
  restart) stop_server && start_server ;;
  status) if is_running; then echo "RUNNING PID $(cat "$PID_FILE")"; else echo "NOT RUNNING"; fi ;;
  logs) tail -n 80 -f "$LOG_FILE" ;;
  *) echo "Usage: $0 {start|stop|restart|status|logs}" >&2; exit 2 ;;
esac
