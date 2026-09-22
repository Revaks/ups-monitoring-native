#!/usr/bin/env bash
# =====================================================================
#  UPS Monitoring (native) — запуск стека
# =====================================================================
#  Поднимает snmp_exporter + Prometheus + Grafana обычными процессами
#  (без Docker). Бинарники скачиваются автоматически при первом запуске.
#
#  Запуск в фоне:        ./run.sh
#  Для systemd:          ./run.sh --foreground
#                        (супервизор: перезапускает упавшие сервисы и
#                         ждёт сигнала, пока его не остановят)
#  Справка:              ./run.sh --help
#
#  Настройки читаются из файла .env рядом со скриптом (его создаёт install.sh):
#    GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD — доступ к Grafana
#    TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID       — уведомления (по умолчанию выкл.)
#    LISTEN_ADDR                                 — 0.0.0.0 (по умолчанию) или 127.0.0.1
#    SNMP_EXPORTER_PORT / PROMETHEUS_PORT / GRAFANA_PORT
#    RETENTION_TIME / RETENTION_SIZE             — сколько хранить историю
#  Подробности: docs/configuration.md
# =====================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

usage() {
  cat <<'EOF'
UPS Monitoring (native) — запуск стека snmp_exporter + Prometheus + Grafana

Использование:
  ./run.sh                 запустить всё в фоне (обычный режим)
  ./run.sh --foreground    запустить супервизором: держит процессы и заново
                           поднимает упавшие (так запускает systemd)
  ./run.sh --help          эта справка

Что делает:
  1. скачивает бинарники в bin/ (если их нет);
  2. подставляет секреты из .env в провижининг алертов;
  3. запускает snmp_exporter, Prometheus, Grafana;
  4. проверяет, что каждый сервис отвечает по HTTP.

Настройки (из .env рядом со скриптом или переменными окружения):
  LISTEN_ADDR=127.0.0.1        слушать только локально (по умолчанию 0.0.0.0)
  SNMP_EXPORTER_PORT=9116      порт snmp_exporter (должен совпадать с prometheus.yml)
  PROMETHEUS_PORT=9090         порт Prometheus
  GRAFANA_PORT=3000            порт Grafana
  RETENTION_TIME=1y            сколько хранить историю Prometheus
  RETENTION_SIZE=               ограничение по объёму (например 10GB), пусто — нет

Остановить:  ./stop.sh        Состояние: ./status.sh
Документация: README.md и каталог docs/
EOF
}

FOREGROUND=0
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--foreground) FOREGROUND=1 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "неизвестный аргумент: $1   (справка: ./run.sh --help)" >&2; exit 2 ;;
  esac
  shift
done

# >>> install.sh: .env >>>
# Подхватываем настройки из .env (логин/пароль Grafana, токен Telegram и прочее).
# Так секреты не попадают в скрипты и конфиги, а Grafana получает их из окружения
# (провижининг grafana/provisioning/alerting/contact-points.yml).
if [ -r "$DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$DIR/.env"
  set +a
fi
# <<< install.sh: .env <<<

BIN_DIR="$DIR/bin"
DATA_DIR="$DIR/data"
mkdir -p "$BIN_DIR" "$DATA_DIR"

# --- версии бинарников (install.sh читает их отсюда) ---
SNMP_VER="0.26.0"
PROM_VER="3.1.0"
GF_VER="11.5.1"
ARCH="linux-amd64"

# --- настройки: значения по умолчанию, переопределяются .env/окружением ---
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
SNMP_EXPORTER_PORT="${SNMP_EXPORTER_PORT:-9116}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
RETENTION_TIME="${RETENTION_TIME:-1y}"
RETENTION_SIZE="${RETENTION_SIZE:-}"
RESTART_DELAY="${RESTART_DELAY:-5}"     # пауза перед перезапуском упавшего сервиса
STOP_TIMEOUT=20                          # сколько секунд ждать завершения при остановке

SNMP_DIR="$BIN_DIR/snmp_exporter-$SNMP_VER.$ARCH"
PROM_DIR="$BIN_DIR/prometheus-$PROM_VER.$ARCH"
GF_DIR="$BIN_DIR/grafana-v$GF_VER"

# =====================================================================
#  Вспомогательные функции
# =====================================================================

warn() { printf '! %s\n' "$*" >&2; }
info() { printf '[i] %s\n' "$*"; }
step() { printf '[+] %s\n' "$*"; }

# Живой ли процесс и тот ли это процесс (защита от переиспользования PID).
process_alive() {  # $1=pid $2=ожидаемое имя процесса (необязательно)
  local pid="$1" want="${2:-}" comm=""
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$want" ] || return 0
  [ -r "/proc/$pid/comm" ] || return 0
  comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
  [ -z "$comm" ] || [ "${comm%%:*}" = "$want" ]
}

# Ждём, пока сервис начнёт отвечать по HTTP.
wait_http() {  # $1=url $2=имя $3=таймаут в секундах
  local url="$1" name="$2" timeout="$3" i=0
  while [ "$i" -lt "$timeout" ]; do
    if curl -fsS -o /dev/null --max-time 3 "$url" 2>/dev/null; then
      printf '    %-14s отвечает\n' "$name"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  printf '    %-14s НЕ отвечает (>%ss)\n' "$name" "$timeout" >&2
  return 1
}

check_ports_busy() {  # предупреждаем, если порты заняты чужими процессами
  local port
  if ! command -v ss >/dev/null 2>&1; then return 0; fi
  for port in "$SNMP_EXPORTER_PORT" "$PROMETHEUS_PORT" "$GRAFANA_PORT"; do
    if ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}\$"; then
      if ! process_alive "$(read_pid snmp_exporter)" "snmp_exporter" \
         && ! process_alive "$(read_pid prometheus)" "prometheus" \
         && ! process_alive "$(read_pid grafana)" "grafana"; then
        warn "порт $port занят другим процессом — сервис на нём не поднимется"
      fi
    fi
  done
}

read_pid() {  # $1=имя сервиса
  cat "$DATA_DIR/$1.pid" 2>/dev/null || true
}

# =====================================================================
#  Бинарники
# =====================================================================

step "Проверяю бинарники..."

if [ ! -x "$SNMP_DIR/snmp_exporter" ]; then
  echo "    скачиваю snmp_exporter v$SNMP_VER..."
  curl -fsSL --retry 3 "https://github.com/prometheus/snmp_exporter/releases/download/v$SNMP_VER/snmp_exporter-$SNMP_VER.$ARCH.tar.gz" -o "$DATA_DIR/.snmp_exporter.tar.gz"
  tar -xzf "$DATA_DIR/.snmp_exporter.tar.gz" -C "$BIN_DIR"
  rm -f "$DATA_DIR/.snmp_exporter.tar.gz"
fi

if [ ! -x "$PROM_DIR/prometheus" ]; then
  echo "    скачиваю prometheus v$PROM_VER..."
  curl -fsSL --retry 3 "https://github.com/prometheus/prometheus/releases/download/v$PROM_VER/prometheus-$PROM_VER.$ARCH.tar.gz" -o "$DATA_DIR/.prometheus.tar.gz"
  tar -xzf "$DATA_DIR/.prometheus.tar.gz" -C "$BIN_DIR"
  rm -f "$DATA_DIR/.prometheus.tar.gz"
fi

if [ ! -x "$GF_DIR/bin/grafana" ]; then
  echo "    скачиваю grafana v$GF_VER..."
  curl -fsSL --retry 3 "https://dl.grafana.com/oss/release/grafana-$GF_VER.$ARCH.tar.gz" -o "$DATA_DIR/.grafana.tar.gz"
  tar -xzf "$DATA_DIR/.grafana.tar.gz" -C "$BIN_DIR"
  rm -f "$DATA_DIR/.grafana.tar.gz"
fi

# =====================================================================
#  Проверки конфигов
# =====================================================================

# Порт snmp_exporter должен совпадать с тем, куда Prometheus шлёт запросы.
if ! grep -qE "replacement:[[:space:]]*(localhost|127\.0\.0\.1):${SNMP_EXPORTER_PORT}\$" "$DIR/prometheus.yml"; then
  warn "в prometheus.yml адрес snmp_exporter не localhost:${SNMP_EXPORTER_PORT}"
  warn "  поправьте в prometheus.yml: replacement: localhost:${SNMP_EXPORTER_PORT}"
fi

# =====================================================================
#  Уведомления об алертах: по умолчанию выключены
# =====================================================================
# Правила (rules.yml) подключены всегда — они считаются и видны в Grafana.
# А контакт-поинт и политика уведомлений создаются только тогда, когда в .env
# заданы TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID: шаблоны *.yml.tpl превращаются
# в рабочие файлы подстановкой текстом (почему не ${VAR} — см. шаблон).
ALERTS_NOTIFICATIONS=0

render_alerting_template() {  # $1=шаблон $2=результат $3=токен $4=chat id
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//@@TELEGRAM_BOT_TOKEN@@/$3}"
    line="${line//@@TELEGRAM_CHAT_ID@@/$4}"
    printf '%s\n' "$line"
  done <"$1" >"$2"
}

# Удаляет только файлы, созданные этим скриптом: если contact-points.yml
# написан вручную, он не трогается.
drop_generated_alerting_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  if head -n 5 "$f" 2>/dev/null | grep -q 'Сгенерировано run.sh'; then
    rm -f "$f"
  else
    warn "$f создан вручную — оставляю как есть"
  fi
}

setup_alerts_notifications() {
  local dir="$DIR/grafana/provisioning/alerting"
  local token="${TELEGRAM_BOT_TOKEN:-}" chat="${TELEGRAM_CHAT_ID:-}"

  if [ ! -f "$dir/contact-points.yml.tpl" ] || [ ! -f "$dir/policies.yml.tpl" ]; then
    warn "шаблоны уведомлений не найдены в $dir — уведомления не настраиваются"
    return 0
  fi

  if [ -n "$token" ] && [ -n "$chat" ]; then
    if render_alerting_template "$dir/contact-points.yml.tpl" "$dir/contact-points.yml" "$token" "$chat" \
       && render_alerting_template "$dir/policies.yml.tpl" "$dir/policies.yml" "$token" "$chat"; then
      ALERTS_NOTIFICATIONS=1
      step "Уведомления: Telegram включён"
    else
      warn "не удалось создать файлы уведомлений — правила останутся без рассылки"
      ALERTS_NOTIFICATIONS=0
    fi
    return 0
  fi

  # Значения не заданы — режим по умолчанию: без уведомлений.
  drop_generated_alerting_file "$dir/contact-points.yml"
  drop_generated_alerting_file "$dir/policies.yml"
  info "уведомления выключены (по умолчанию): алерты видны в Grafana -> Alerting"
  info "  включить: TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID в $DIR/.env (docs/alerts.md)"
}

# =====================================================================
#  Окружение Grafana
# =====================================================================

export DASHBOARDS_PATH="$DIR/grafana/dashboards"
export GF_PATHS_DATA="$DATA_DIR/grafana"
export GF_PATHS_PROVISIONING="$DIR/grafana/provisioning"
export GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
export GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
export GF_USERS_ALLOW_SIGN_UP=false
export GF_SERVER_HTTP_ADDR="$LISTEN_ADDR"
export GF_SERVER_HTTP_PORT="$GRAFANA_PORT"

# =====================================================================
#  Запуск и остановка сервисов
# =====================================================================

start_snmp_exporter() {
  nohup "$SNMP_DIR/snmp_exporter" \
    --config.file="$DIR/snmp.yml" \
    --config.expand-environment-variables \
    --web.listen-address="${LISTEN_ADDR}:${SNMP_EXPORTER_PORT}" \
    >>"$DATA_DIR/snmp_exporter.log" 2>&1 &
  echo $! >"$DATA_DIR/snmp_exporter.pid"
}

start_prometheus() {
  local args=(
    "--config.file=$DIR/prometheus.yml"
    "--storage.tsdb.path=$DATA_DIR/prometheus"
    "--web.listen-address=${LISTEN_ADDR}:${PROMETHEUS_PORT}"
    "--storage.tsdb.retention.time=$RETENTION_TIME"
  )
  [ -n "$RETENTION_SIZE" ] && args+=("--storage.tsdb.retention.size=$RETENTION_SIZE")
  nohup "$PROM_DIR/prometheus" "${args[@]}" >>"$DATA_DIR/prometheus.log" 2>&1 &
  echo $! >"$DATA_DIR/prometheus.pid"
}

start_grafana() {
  nohup "$GF_DIR/bin/grafana" server --homepath="$GF_DIR" >>"$DATA_DIR/grafana.log" 2>&1 &
  echo $! >"$DATA_DIR/grafana.pid"
}

start_service() {  # $1 = имя сервиса
  case "$1" in
    snmp_exporter) step "Запускаю snmp_exporter (${LISTEN_ADDR}:${SNMP_EXPORTER_PORT})..."; start_snmp_exporter ;;
    prometheus)    step "Запускаю Prometheus (${LISTEN_ADDR}:${PROMETHEUS_PORT})..."; start_prometheus ;;
    grafana)       step "Запускаю Grafana (${LISTEN_ADDR}:${GRAFANA_PORT})..."; start_grafana ;;
    *) warn "неизвестный сервис: $1"; return 1 ;;
  esac
}

health_check() {
  local fails=0
  step "Проверяю, что сервисы отвечают"
  wait_http "http://127.0.0.1:${SNMP_EXPORTER_PORT}/" "snmp_exporter" 20 || fails=$((fails + 1))
  wait_http "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy" "Prometheus" 40 || fails=$((fails + 1))
  wait_http "http://127.0.0.1:${GRAFANA_PORT}/api/health" "Grafana" 60 || fails=$((fails + 1))
  if [ "$fails" -gt 0 ]; then
    warn "часть сервисов не поднялась. Посмотрите логи:"
    warn "  tail -n 30 $DATA_DIR/snmp_exporter.log $DATA_DIR/prometheus.log $DATA_DIR/grafana.log"
    warn "  занятые порты: ss -ltnp | grep -E ':(${SNMP_EXPORTER_PORT}|${PROMETHEUS_PORT}|${GRAFANA_PORT})\\b'"
    return 1
  fi
  return 0
}

print_summary() {
  echo
  echo "Готово:"
  printf '  Grafana        http://%s:%s   (логин/пароль из .env: %s)\n' \
    "$(host_addr)" "$GRAFANA_PORT" "${GRAFANA_ADMIN_USER:-admin}"
  printf '  Prometheus     http://%s:%s\n' "$(host_addr)" "$PROMETHEUS_PORT"
  printf '  snmp_exporter  http://%s:%s\n' "$(host_addr)" "$SNMP_EXPORTER_PORT"
  echo
  echo "  Дашборд:    Grafana -> «ИБП — обзор»"
  echo "  Алерты:     Grafana -> Alerting -> Alert rules (папка UPS)"
  if [ "$ALERTS_NOTIFICATIONS" = 1 ]; then
    echo "              уведомления: Telegram включён"
  else
    echo "              уведомления: выключены (по умолчанию), только интерфейс"
  fi
  echo "  История:    хранится $RETENTION_TIME${RETENTION_SIZE:+ (не больше $RETENTION_SIZE)}"
  echo "  Логи:       $DATA_DIR/*.log"
  echo "  Остановить: $DIR/stop.sh"
  echo "  Проверить:  $DIR/status.sh"
}

host_addr() {
  if [ "$LISTEN_ADDR" = "0.0.0.0" ]; then printf 'localhost'; else printf '%s' "$LISTEN_ADDR"; fi
}

# =====================================================================
#  main
# =====================================================================

setup_alerts_notifications

check_ports_busy

# Второй супервизор не нужен: он начал бы дублировать сервисы и драться за порты.
if [ "$FOREGROUND" = 1 ]; then
  existing="$(cat "$DATA_DIR/run.pid" 2>/dev/null || true)"
  if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
    line=""
    [ -r "/proc/$existing/cmdline" ] && line="$(tr '\0' ' ' <"/proc/$existing/cmdline" 2>/dev/null || true)"
    case "$line" in
      *run.sh*|"")
        warn "супервизор уже работает (pid $existing) — второй запуск не нужен"
        warn "  состояние: $DIR/status.sh, остановить: $DIR/stop.sh"
        exit 1 ;;
    esac
  fi
  rm -f "$DATA_DIR/run.pid"
fi

# Останавливаем то, что осталось от прошлого запуска (аккуратно, с ожиданием).
if [ -x "$DIR/stop.sh" ]; then
  "$DIR/stop.sh" --quiet >/dev/null 2>&1 || true
fi

if [ "$FOREGROUND" = 1 ]; then
  # Режим супервизора: процессы наши дети, упавшие перезапускаем,
  # по SIGTERM/SIGINT аккуратно останавливаем всё и выходим.
  # Свой pid пишем в data/run.pid, чтобы stop.sh остановил и супервизор
  # (иначе он поднял бы сервисы заново через RESTART_DELAY секунд).
  echo $$ >"$DATA_DIR/run.pid"
  # shellcheck disable=SC2317
  on_signal() {
    echo
    info "получен сигнал остановки — завершаю сервисы..."
    rm -f "$DATA_DIR/run.pid"
    "$DIR/stop.sh" >/dev/null 2>&1 || true
    exit 0
  }
  trap on_signal TERM INT

  for svc in snmp_exporter prometheus grafana; do start_service "$svc"; done
  health_check || warn "сервисы не поднялись — работаю дальше, перезапущу при падении"

  while :; do
    wait -n || true
    for svc in snmp_exporter prometheus grafana; do
      pid="$(read_pid "$svc")"
      if ! process_alive "$pid" "$svc"; then
        warn "$svc остановился (pid ${pid:-нет}) — перезапускаю через ${RESTART_DELAY}s"
        sleep "$RESTART_DELAY"
        start_service "$svc"
      fi
    done
  done
fi

# Обычный режим: запускаем и выходим, процессы остаются работать в фоне.
for svc in snmp_exporter prometheus grafana; do start_service "$svc"; done

if health_check; then
  print_summary
else
  print_summary
  exit 1
fi
