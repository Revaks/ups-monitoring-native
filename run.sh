#!/usr/bin/env bash
# Запуск мониторинга ИБП без Docker.
# Скачивает бинарники (если их ещё нет) и запускает snmp_exporter, Prometheus и Grafana.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

BIN_DIR="$DIR/bin"
DATA_DIR="$DIR/data"
mkdir -p "$BIN_DIR" "$DATA_DIR"

SNMP_VER="0.26.0"
PROM_VER="3.1.0"
GF_VER="11.5.1"
ARCH="linux-amd64"

echo "[+] Проверяю бинарники..."

# --- snmp_exporter ---
SNMP_DIR="$BIN_DIR/snmp_exporter-$SNMP_VER.$ARCH"
if [ ! -x "$SNMP_DIR/snmp_exporter" ]; then
  echo "    скачиваю snmp_exporter v$SNMP_VER..."
  curl -fsSL "https://github.com/prometheus/snmp_exporter/releases/download/v$SNMP_VER/snmp_exporter-$SNMP_VER.$ARCH.tar.gz" -o /tmp/snmp_exporter.tar.gz
  tar -xzf /tmp/snmp_exporter.tar.gz -C "$BIN_DIR"
  rm -f /tmp/snmp_exporter.tar.gz
fi

# --- prometheus ---
PROM_DIR="$BIN_DIR/prometheus-$PROM_VER.$ARCH"
if [ ! -x "$PROM_DIR/prometheus" ]; then
  echo "    скачиваю prometheus v$PROM_VER..."
  curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v$PROM_VER/prometheus-$PROM_VER.$ARCH.tar.gz" -o /tmp/prometheus.tar.gz
  tar -xzf /tmp/prometheus.tar.gz -C "$BIN_DIR"
  rm -f /tmp/prometheus.tar.gz
fi

# --- grafana ---
GF_DIR="$BIN_DIR/grafana-v$GF_VER"
if [ ! -x "$GF_DIR/bin/grafana" ]; then
  echo "    скачиваю grafana v$GF_VER..."
  curl -fsSL "https://dl.grafana.com/oss/release/grafana-$GF_VER.$ARCH.tar.gz" -o /tmp/grafana.tar.gz
  tar -xzf /tmp/grafana.tar.gz -C "$BIN_DIR"
  rm -f /tmp/grafana.tar.gz
fi

# Останавливаем, если что-то уже запущено
"$DIR/stop.sh" >/dev/null 2>&1 || true

# Переменные окружения для Grafana
export DASHBOARDS_PATH="$DIR/grafana/dashboards"
export GF_PATHS_DATA="$DATA_DIR/grafana"
export GF_PATHS_PROVISIONING="$DIR/grafana/provisioning"
export GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
export GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
export GF_USERS_ALLOW_SIGN_UP=false

echo "[+] Запускаю snmp_exporter (localhost:9116)..."
nohup "$SNMP_DIR/snmp_exporter" --config.file="$DIR/snmp.yml" >"$DATA_DIR/snmp_exporter.log" 2>&1 &
echo $! > "$DATA_DIR/snmp_exporter.pid"

echo "[+] Запускаю Prometheus (localhost:9090)..."
nohup "$PROM_DIR/prometheus" --config.file="$DIR/prometheus.yml" --storage.tsdb.path="$DATA_DIR/prometheus" >"$DATA_DIR/prometheus.log" 2>&1 &
echo $! > "$DATA_DIR/prometheus.pid"

echo "[+] Запускаю Grafana (localhost:3000)..."
nohup "$GF_DIR/bin/grafana" server --homepath="$GF_DIR" >"$DATA_DIR/grafana.log" 2>&1 &
echo $! > "$DATA_DIR/grafana.pid"

sleep 2
echo
echo "Готово:"
echo "  Grafana        http://localhost:3000   (логин/пароль: admin / admin или из GRAFANA_ADMIN_*)"
echo "  Prometheus     http://localhost:9090"
echo "  snmp_exporter  http://localhost:9116"
echo
echo "Логи:       $DATA_DIR/*.log"
echo "Остановить: $DIR/stop.sh"
