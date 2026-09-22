#!/usr/bin/env bash
# =====================================================================
#  UPS Monitoring (native) — остановка стека
# =====================================================================
#  Останавливает Grafana, Prometheus и snmp_exporter аккуратно:
#  SIGTERM -> ожидание завершения -> SIGKILL, если процесс не завершился.
#  Так Prometheus успевает дописать данные на диск, а Grafana — закрыть
#  базу (иначе в data/grafana.log появляется «database is locked»).
#
#  Если pid-файла нет (например, стек запускали вручную), скрипт найдёт
#  процессы по пути к бинарникам этого каталога.
#
#  Использование:
#    ./stop.sh                 остановить всё
#    ./stop.sh --quiet         без вывода (используется из run.sh)
#    ./stop.sh --timeout 30    ждать завершения до 30 секунд на сервис
# =====================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$DIR/data"

QUIET=0
TIMEOUT=20
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quiet)   QUIET=1 ;;
    -t|--timeout) TIMEOUT="${2:-20}"; shift ;;
    -h|--help)
      # печатаем шапку файла: комментарии до первой команды
      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0 ;;
    *) echo "неизвестный аргумент: $1   (справка: ./stop.sh --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { [ "$QUIET" = 1 ] || printf '[+] %s\n' "$*"; }

# $1=pid $2=ожидаемое имя процесса — защита от убийства чужого процесса
# с переиспользованным PID.
process_alive() {
  local pid="$1" want="${2:-}" comm=""
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$want" ] || return 0
  [ -r "/proc/$pid/comm" ] || return 0
  comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
  [ -z "$comm" ] || [ "${comm%%:*}" = "$want" ]
}

# Процессы этого каталога (на случай потерянного pid-файла).
pids_by_path() {  # $1 = имя сервиса
  pgrep -f "^${DIR}/bin/.*/${1}( |$)" 2>/dev/null || true
}

stop_one() {  # $1 = имя сервиса
  local name="$1"
  local pidfile="$DATA_DIR/$1.pid"
  local pid="" waited=0

  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    rm -f "$pidfile"
  else
    pid=""
  fi

  if [ -n "$pid" ] && ! process_alive "$pid" "$name"; then
    say "$name: уже не работает"
    pid=""
  fi

  if [ -z "$pid" ]; then
    pid="$(pids_by_path "$name" | head -n 1)"
    [ -n "$pid" ] || { say "$name: не запущен"; return 0; }
    say "$name: найден без pid-файла (pid $pid)"
  fi

  say "останавливаю $name (pid $pid)..."
  kill "$pid" 2>/dev/null || true

  while process_alive "$pid" "$name" && [ "$waited" -lt "$TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if process_alive "$pid" "$name"; then
    printf '! %s не завершился за %ss — завершаю принудительно (SIGKILL)\n' "$name" "$TIMEOUT" >&2
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
  fi
}

# Супервизор (run.sh --foreground, так запускает systemd) сам останавливает
# сервисы по сигналу, поэтому сначала просим остановиться его — иначе он
# поднял бы сервисы заново через несколько секунд.
stop_supervisor() {
  local pidfile="$DATA_DIR/run.pid" pid waited=0 line
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  rm -f "$pidfile"
  [ -n "$pid" ] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    say "супервизор: уже не работает"
    return 0
  fi
  # не убиваем чужой процесс с переиспользованным PID
  if [ -r "/proc/$pid/cmdline" ]; then
    line="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$line" in
      *run.sh*) : ;;
      *) say "pid $pid — не супервизор run.sh, пропускаю"; return 0 ;;
    esac
  fi
  say "останавливаю супервизор run.sh (pid $pid)..."
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf '! супервизор не завершился за %ss — SIGKILL\n' "$TIMEOUT" >&2
    kill -9 "$pid" 2>/dev/null || true
  fi
}

stop_supervisor

for svc in grafana prometheus snmp_exporter; do
  stop_one "$svc"
done

say "остановлено"
exit 0
