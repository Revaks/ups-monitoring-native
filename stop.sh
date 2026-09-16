#!/usr/bin/env bash
# Останавливает snmp_exporter, Prometheus и Grafana.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$DIR/data"

for name in grafana prometheus snmp_exporter; do
  pidfile="$DATA_DIR/$name.pid"
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "[+] Останавливаю $name (pid $pid)..."
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
done
echo "Остановлено."
