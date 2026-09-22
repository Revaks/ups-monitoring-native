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
DATA_DIR="$DIR/data"

# >>> install.sh: .env >>>
if [ -r "$DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$DIR/.env"
  set +a
fi
# <<< install.sh: .env <<<

LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
SNMP_EXPORTER_PORT="${SNMP_EXPORTER_PORT:-9116}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"

if [ "$LISTEN_ADDR" = "0.0.0.0" ]; then
  HOST="localhost"
  FROM_NET="да (слушает все интерфейсы)"
else
  HOST="$LISTEN_ADDR"
  FROM_NET="нет (только $LISTEN_ADDR)"
fi

alive() { kill -0 "$1" 2>/dev/null; }

check_service() {  # $1=имя $2=порт $3=url для проверки
  local name="$1" port="$2" url="$3" pid state http
  pid="$(cat "$DATA_DIR/$name.pid" 2>/dev/null || true)"
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
check_service snmp_exporter "$SNMP_EXPORTER_PORT" "http://127.0.0.1:${SNMP_EXPORTER_PORT}/"
check_service prometheus    "$PROMETHEUS_PORT"    "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy"
check_service grafana       "$GRAFANA_PORT"       "http://127.0.0.1:${GRAFANA_PORT}/api/health"

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

echo
echo "Доступ:"
echo "  Grafana        http://${HOST}:${GRAFANA_PORT}   (логин/пароль из .env)"
echo "  Prometheus     http://${HOST}:${PROMETHEUS_PORT}"
echo "  snmp_exporter  http://${HOST}:${SNMP_EXPORTER_PORT}"
echo "  из сети:       $FROM_NET   (меняется через LISTEN_ADDR в .env, docs/security.md)"

echo
echo "Логи:    tail -n 50 $DATA_DIR/*.log"
echo "Управление: ./run.sh | ./stop.sh | ./status.sh"
