#!/usr/bin/env bash
# =====================================================================
#  UPS Monitoring (native) — состояние стека
# =====================================================================
#  Показывает, что запущено, отвечают ли сервисы и куда идти смотреть.
#  Ничего не меняет — можно запускать в любой момент.
#
#  Использование: ./status.sh
# =====================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# >>> install.sh: .env >>>
if [ -r "$DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$DIR/.env"
  set +a
fi
# <<< install.sh: .env <<<

# Каталоги могли быть вынесены на другой диск (DATA_DIR/LOG_DIR в .env).
DATA_DIR="${DATA_DIR:-$DIR/data}"
LOG_DIR="${LOG_DIR:-$DATA_DIR}"

LOG_MAX_SIZE="${LOG_MAX_SIZE:-10M}"
LOG_KEEP_PERCENT="${LOG_KEEP_PERCENT:-10}"

LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
SNMP_EXPORTER_PORT="${SNMP_EXPORTER_PORT:-9116}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
SNMP_SHARDS="${SNMP_SHARDS:-1}"
case "$SNMP_SHARDS" in ''|*[!0-9]*) SNMP_SHARDS=1 ;; esac
[ "$SNMP_SHARDS" -ge 1 ] || SNMP_SHARDS=1

# Слот шарда -> его порт
shard_port() { printf '%s' "$((SNMP_EXPORTER_PORT + $1))"; }

if [ "$LISTEN_ADDR" = "0.0.0.0" ]; then
  HOST="localhost"
  FROM_NET="да (слушает все интерфейсы)"
else
  HOST="$LISTEN_ADDR"
  FROM_NET="нет (только $LISTEN_ADDR)"
fi

# Процесс жив? Обычная kill -0 не работает, если сервисы запущены от root,
# а status.sh запущен обычным пользователем (нет прав послать сигнал, хотя
# процесс работает). Поэтому дополнительно смотрим /proc — он доступен всем.
alive() {  # $1 = pid
  [ -n "$1" ] || return 1
  kill -0 "$1" 2>/dev/null && return 0
  [ -d "/proc/$1" ] && return 0
  return 1
}

# Путь к pid-файлу слота $1. DATA_DIR появился в 1.4.0: если стек запущен более
# старым run.sh (или его запускали до переноса DATA_DIR), pid-файлы лежат в
# <каталог>/data — проверяем и там, иначе статус врал бы «ОСТАНОВЛЕН».
pid_file() {  # $1 = слот
  local d
  for d in "$DATA_DIR" "$DIR/data"; do
    [ -f "$d/$1.pid" ] && { printf '%s' "$d/$1.pid"; return 0; }
  done
  printf '%s' "$DATA_DIR/$1.pid"
}

check_service() {  # $1=слот $2=порт $3=url для проверки
  local name="$1" port="$2" url="$3" pid state http
  pid="$(cat "$(pid_file "$name")" 2>/dev/null || true)"
  if [ -n "$pid" ] && alive "$pid"; then
    state="запущен (pid $pid)"
  else
    state="ОСТАНОВЛЕН"
  fi
  if curl -fsS -o /dev/null --max-time 3 "$url" 2>/dev/null; then
    http="отвечает"
  else
    http="не отвечает"
  fi
  printf '  %-14s %-20s порт %-5s %s\n' "$name" "$state" "$port" "$http"
}

echo "UPS Monitoring — состояние ($DIR)"
echo
echo "Сервисы:"
if [ "$SNMP_SHARDS" = 1 ]; then
  check_service snmp_exporter "$(shard_port 0)" "http://127.0.0.1:$(shard_port 0)/"
else
  i=0
  while [ "$i" -lt "$SNMP_SHARDS" ]; do
    if [ "$i" = 0 ]; then slot="snmp_exporter"; else slot="snmp_exporter-$i"; fi
    check_service "$slot" "$(shard_port "$i")" "http://127.0.0.1:$(shard_port "$i")/"
    i=$((i + 1))
  done
fi
check_service prometheus    "$PROMETHEUS_PORT"    "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy"
check_service grafana       "$GRAFANA_PORT"       "http://127.0.0.1:${GRAFANA_PORT}/api/health"

# Сколько ИБП попало на каждый шард (из Prometheus) — заодно проверка,
# что шардинг реально распределяет, а не гонит всё в первый процесс.
if [ "$SNMP_SHARDS" -gt 1 ]; then
  targets_json="$(curl -fsS --max-time 5 "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/targets" 2>/dev/null || true)"
  if [ -n "$targets_json" ]; then
    dist=""
    i=0
    while [ "$i" -lt "$SNMP_SHARDS" ]; do
      p="$(shard_port "$i")"
      # именно scrapeUrl (в цели есть ещё globalUrl с тем же портом)
      n="$(printf '%s' "$targets_json" | grep -o "scrapeUrl\":\"[^\"]*:$p/snmp" | wc -l | tr -d ' ')"
      dist="${dist}${n}:${p} "
      i=$((i + 1))
    done
    printf '  %-14s ИБП по шардам (штук:порт): %s\n' "распределение" "$dist"
  else
    printf '  %-14s нет данных (Prometheus не ответил)\n' "распределение"
  fi
fi

echo
echo "Список ИБП ($DIR/targets.yml):"
if [ -f "$DIR/targets.yml" ]; then
  # поддерживаем оба формата: - targets: [10.0.0.5] и многострочный список
  ups_count="$(awk '
    /^[[:space:]]*-[[:space:]]*targets:[[:space:]]*\[/ {
      line = $0; sub(/.*\[/, "", line); sub(/\].*/, "", line)
      c = split(line, a, ",")
      for (i = 1; i <= c; i++) if (a[i] ~ /[^[:space:]]/) n++
      next
    }
    /^[[:space:]]+-[[:space:]]+[^[:space:]#]/ && $0 !~ /targets:/ { n++ }
    END { print n + 0 }
  ' "$DIR/targets.yml")"
  echo "  устройств: $ups_count"
  if [ "$ups_count" = 0 ]; then
    echo "  (пусто — впишите IP своих ИБП, см. docs/configuration.md)"
  fi
else
  echo "  файла нет"
fi

echo
echo "Алерты и уведомления:"
if [ -f "$DIR/grafana/provisioning/alerting/rules.yml" ]; then
  rules_count="$(grep -c '^      - uid:' "$DIR/grafana/provisioning/alerting/rules.yml" 2>/dev/null || echo 0)"
  echo "  правил: $rules_count   (Grafana -> Alerting -> Alert rules, папка UPS)"
else
  echo "  файл правил не найден"
fi
if [ -f "$DIR/grafana/provisioning/alerting/contact-points.yml" ]; then
  echo "  уведомления: Telegram включён"
else
  echo "  уведомления: выключены (по умолчанию), алерты видны в интерфейсе Grafana"
fi

if curl -fsS --max-time 5 "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/status/flags" 2>/dev/null \
   | grep -q '"storage.tsdb.retention.time"'; then
  ret="$(curl -fsS --max-time 5 "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/status/flags" 2>/dev/null \
        | sed -n 's/.*"storage.tsdb.retention.time":"\([^"]*\)".*/\1/p')"
  echo "  хранение истории Prometheus: ${ret:-по умолчанию}"
fi

# Каким конфигом реально работает Prometheus: run.sh собирает рабочую копию
# из prometheus.yml, подставляя адреса экспортёров и правила шардинга.
if [ -f "$DATA_DIR/prometheus.yml" ]; then
  if grep -q 'сгенерировано run.sh' "$DATA_DIR/prometheus.yml" 2>/dev/null; then
    echo "  конфиг Prometheus: $DATA_DIR/prometheus.yml (собран run.sh из prometheus.yml)"
  else
    echo "  конфиг Prometheus: $DATA_DIR/prometheus.yml"
  fi
  echo "  шардов экспортёра: $SNMP_SHARDS   (SNMP_SHARDS в .env, docs/scaling.md)"
else
  echo "  конфиг Prometheus: prometheus.yml (рабочая копия ещё не собрана)"
fi

# Размер файла в удобном виде: меньше килобайта — в байтах (иначе «0K» врёт).
file_size() {  # $1 = файл
  local n
  n="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -lt 1024 ]; then printf '%s байт' "$n"; else printf '%sK' "$((n / 1024))"; fi
}

echo
echo "Логи ($LOG_DIR):"
if [ -d "$LOG_DIR" ]; then
  logs_found=0
  for f in "$LOG_DIR"/*.log "$LOG_DIR"/*/*.log; do
    [ -f "$f" ] || continue
    logs_found=1
    printf '  %-28s %10s\n' "${f#"$LOG_DIR"/}" "$(file_size "$f")"
  done
  [ "$logs_found" = 1 ] || echo "  файлов ещё нет"
  echo "  всего в каталоге: $(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)"
else
  echo "  каталога нет"
fi

# pid ротатора: run.sh 1.4.0+ пишет его в LOG_DIR, но мог остаться и в DATA_DIR
# (перенос каталогов) — проверяем оба места, как это делает stop.sh.
rot_pid=""
for rot_file in "$LOG_DIR/rotate.pid" "$DATA_DIR/rotate.pid" "$DIR/data/rotate.pid"; do
  [ -f "$rot_file" ] || continue
  rot_pid="$(cat "$rot_file" 2>/dev/null || true)"
  [ -n "$rot_pid" ] && break
done
if [ "$LOG_MAX_SIZE" = "0" ]; then
  echo "  ротация: выключена (LOG_MAX_SIZE=0)"
elif [ -n "$rot_pid" ] && alive "$rot_pid"; then
  echo "  ротация: до $LOG_MAX_SIZE на файл, хвост ${LOG_KEEP_PERCENT}%, ротатор работает (pid $rot_pid)"
elif ! grep -q -- '--rotate-daemon' "$DIR/run.sh" 2>/dev/null; then
  # run.sh старее 1.4.0: он умеет только обрезать логи при запуске.
  echo "  ротация: run.sh этой версии не умеет обрезать логи по размеру"
  echo "           (нужен run.sh 1.4.0+: обновите установку, LOG_MAX_SIZE не действует)"
else
  echo "  ротация: до $LOG_MAX_SIZE на файл, хвост ${LOG_KEEP_PERCENT}%, ротатор НЕ запущен"
  echo "           (поднимется при запуске: ./run.sh; сейчас логи растут без обрезки)"
fi
if [ -f "/etc/logrotate.d/ups-monitoring" ]; then
  echo "  logrotate: правило /etc/logrotate.d/ups-monitoring (неделя × 8, сжатие)"
fi
if [ "$LOG_DIR" != "$DATA_DIR" ]; then
  echo "  данные (история Prometheus, БД Grafana): $DATA_DIR"
fi

echo
echo "Доступ:"
echo "  Grafana        http://${HOST}:${GRAFANA_PORT}   (логин/пароль из .env)"
echo "  Prometheus     http://${HOST}:${PROMETHEUS_PORT}"
echo "  snmp_exporter  http://${HOST}:${SNMP_EXPORTER_PORT}"
echo "  из сети:       $FROM_NET   (меняется через LISTEN_ADDR в .env, docs/security.md)"

echo
echo "Хвост логов:  tail -n 50 $LOG_DIR/*.log"
echo "Обрезать сейчас: ./run.sh --rotate-now   (обычно не нужно — ротатор сам)"
echo "Управление: ./run.sh | ./stop.sh | ./status.sh"
