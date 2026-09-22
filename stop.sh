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
# с переиспользованным PID. /proc проверяем первым: kill -0 не работает, когда
# сервисы запущены от root, а stop.sh запущен обычным пользователем (нет прав
# послать сигнал), хотя процессы живы.
process_alive() {
  local pid="$1" want="${2:-}" comm=""
  [ -n "$pid" ] || return 1
  if [ -r "/proc/$pid/comm" ]; then
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    if [ -n "$want" ] && [ -n "$comm" ] && [ "${comm%%:*}" != "$want" ]; then
      return 1
    fi
    return 0
  fi
  kill -0 "$pid" 2>/dev/null
}

# Процессы этого каталога (на случай потерянного pid-файла). $1 — имя процесса
# (snmp_exporter/prometheus/grafana): у всех шардов экспортёра оно одно и то же.
pids_by_path() {  # $1 = имя процесса
  pgrep -f "^${DIR}/bin/.*/${1}( |$)" 2>/dev/null || true
}

# Имя процесса для слота: snmp_exporter-2 -> snmp_exporter.
service_comm() {  # $1 = слот
  case "$1" in
    snmp_exporter*) printf 'snmp_exporter' ;;
    prometheus)     printf 'prometheus' ;;
    grafana)        printf 'grafana' ;;
    *)              printf '%s' "$1" ;;
  esac
}

# Слоты, которые нужно остановить: grafana, prometheus и все шарды экспортёра
# (по pid-файлам — чтобы остановить и то, что запущено с другим SNMP_SHARDS).
stop_slots() {
  local f
  printf 'grafana\nprometheus\nsnmp_exporter\n'
  for f in "$DATA_DIR"/snmp_exporter-*.pid; do
    [ -e "$f" ] || continue
    f="${f##*/}"
    printf '%s\n' "${f%.pid}"
  done | sort -u -r
}

stop_one() {  # $1 = слот
  local name="$1"
  local comm="$(service_comm "$1")"
  local pidfile="$DATA_DIR/$1.pid"
  local pid="" waited=0

  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    rm -f "$pidfile"
  else
    pid=""
  fi

  if [ -n "$pid" ] && ! process_alive "$pid" "$comm"; then
    say "$name: уже не работает"
    pid=""
  fi

  if [ -z "$pid" ]; then
    pid="$(pids_by_path "$comm" | head -n 1)"
    [ -n "$pid" ] || { say "$name: не запущен"; return 0; }
    say "$name: найден без pid-файла (pid $pid)"
  fi

  say "останавливаю $name (pid $pid)..."
  kill "$pid" 2>/dev/null || true

  while process_alive "$pid" "$comm" && [ "$waited" -lt "$TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if process_alive "$pid" "$comm"; then
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

while IFS= read -r slot; do
  stop_one "$slot"
done <<EOF
$(stop_slots)
EOF

say "остановлено"
exit 0
