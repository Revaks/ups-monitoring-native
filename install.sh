#!/usr/bin/env bash
# =====================================================================
#  ups-monitoring-native — установщик
# =====================================================================
#  Ставит стек мониторинга ИБП (snmp_exporter + Prometheus + Grafana)
#  обычными процессами, без Docker. Всё нужное скачивается само.
#
#  Быстрый старт (от root):
#    curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh | sudo bash
#
#  Без вопросов, со своими параметрами:
#    curl -fsSL .../install.sh | sudo bash -s -- --yes \
#         --targets '192.168.1.10:UPS-01:Узел 1,192.168.1.11:UPS-02' \
#         --password 'M0nitoring-2026'
#
#  Все флаги: install.sh --help
#  Требуется только bash, curl, tar и sha256sum (все есть в базовой системе).
# =====================================================================

set -Eeuo pipefail

INSTALLER_VERSION="1.0.0"
REPO_SLUG="Revaks/ups-monitoring-native"
DEFAULT_REF="main"
DEFAULT_DIR="/opt/ups-monitoring-native"
SERVICE_NAME="ups-monitoring"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TTY="/dev/tty"

# --- параметры (значения по умолчанию) ---
INSTALL_DIR="$DEFAULT_DIR"
REF="$DEFAULT_REF"
REF_GIVEN=0                 # 1, если версию указали явно через --ref
TARGETS_SPEC=""
COMMUNITY=""
GF_USER=""
GF_PASSWORD=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
ASSUME_YES=0
SYSTEMD_MODE="auto"        # auto | yes | no
DO_START=1
DO_DOWNLOAD=1
DO_UNINSTALL=0
DO_PURGE=0

# --- переменные, заполняемые по ходу выполнения ---
ARCH=""
SYSTEMD="no"
STAGE_ROOT=""
STAGE_DIR=""
SELF_CMD="install.sh"
SELF_PIPED=0                # 1, если скрипт пришёл по пайпу (`curl | bash`)
KEEP_TARGETS=0
KEEP_ENV=0
GENERATED_PASSWORD=0
declare -a ENTRIES=()      # элементы вида "ip|имя|расположение"

# =====================================================================
#  Вывод
# =====================================================================

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
info() { printf '    %s\n' "$*" >&2; }
ok()   { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

have_tty() { [ -r "$TTY" ] && [ -w "$TTY" ]; }

# Спрашивает строку. Вывод идёт на /dev/tty, поэтому работает и при `curl | bash`.
# $1 — вопрос, $2 — значение по умолчанию.
prompt() {
  local text="$1" def="${2-}" ans=""
  if [ -n "$def" ]; then
    printf '    %s [%s]: ' "$text" "$def" >"$TTY"
  else
    printf '    %s: ' "$text" >"$TTY"
  fi
  IFS= read -r ans <"$TTY" || ans=""
  [ -n "$ans" ] || ans="$def"
  printf '%s' "$ans"
}

# Да/нет. $1 — вопрос, $2 — ответ по умолчанию (y/n).
prompt_yesno() {
  local text="$1" def="${2:-y}" hint ans=""
  case "$def" in y|Y) hint="Y/n" ;; *) hint="y/N" ;; esac
  printf '    %s [%s]: ' "$text" "$hint" >"$TTY"
  IFS= read -r ans <"$TTY" || ans=""
  [ -n "$ans" ] || ans="$def"
  case "$ans" in
    y|Y|yes|YES|Yes|д|Д|да|Да) return 0 ;;
    *) return 1 ;;
  esac
}

# =====================================================================
#  Справка
# =====================================================================

usage() {
  cat <<EOF
UPS Monitoring (native) — установщик v${INSTALLER_VERSION}

Устанавливает snmp_exporter + Prometheus + Grafana как обычные процессы
(без Docker) и, если в системе есть systemd, включает автозапуск.

Использование:
  curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/main/install.sh | sudo bash
  sudo ./install.sh [опции]

Основное:
  -d, --dir PATH          каталог установки (по умолчанию ${DEFAULT_DIR})
  -r, --ref REF           версия: тег (v1.1.1, v1.0.0) или ветка main.
                          Список версий — CHANGELOG.md.
                          Если --ref не указан при повторном запуске, остаётся
                          ранее установленная версия.
  -y, --yes               не задавать вопросов, использовать значения по умолчанию
  -h, --help              эта справка
  -V, --version           версия установщика

Настройка (иначе спросит интерактивно):
  -t, --targets SPEC      список ИБП: "IP[:ИМЯ[:РАСПОЛОЖЕНИЕ]]" через запятую,
                          напр. '192.168.1.10:UPS-01:Узел 1,192.168.1.11'
  -c, --community STR     SNMP community (по умолчанию public)
  -u, --user NAME         логин администратора Grafana (по умолчанию admin)
  -p, --password PASS     пароль администратора Grafana
                          (если не задан — сгенерируется случайный)

Алерты (необязательно, значения хранятся в .env):
      --telegram-token T  токен бота Telegram (получить у @BotFather)
      --telegram-chat ID  id чата/канала Telegram для уведомлений
                          (для группы/канала — отрицательное число)
                          Без этих значений правила работают, но уведомления
                          не отправляются: видны только в Grafana -> Alerting.

Поведение:
      --systemd           всегда ставить systemd-юнит (автозапуск после ребута)
      --no-systemd        не трогать systemd, запускать через run.sh
      --no-download       не скачивать бинарники самому, доверить это run.sh
      --no-start          только разложить файлы и настройки, не запускать
      --uninstall         удалить systemd-юнит и остановить стек
      --purge             вместе с --uninstall удалить и каталог установки

Примеры:
  # интерактивно
  sudo ./install.sh

  # без вопросов, два ИБП
  sudo ./install.sh -y -t '192.168.1.10:UPS-01:Узел 1,192.168.1.11:UPS-02' -p 'Str0ng-Pass'

  # только разложить файлы, без запуска
  sudo ./install.sh -y --no-start --dir /opt/ups
EOF
}

# =====================================================================
#  Разбор аргументов
# =====================================================================

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--dir)        [ $# -ge 2 ] || die "для $1 нужен путь"; INSTALL_DIR="$2"; shift 2 ;;
      -r|--ref)        [ $# -ge 2 ] || die "для $1 нужна ветка или тег"; REF="$2"; REF_GIVEN=1; shift 2 ;;
      -t|--targets)    [ $# -ge 2 ] || die "для $1 нужен список"; TARGETS_SPEC="$2"; shift 2 ;;
      -c|--community)  [ $# -ge 2 ] || die "для $1 нужна строка"; COMMUNITY="$2"; shift 2 ;;
      -u|--user)       [ $# -ge 2 ] || die "для $1 нужен логин"; GF_USER="$2"; shift 2 ;;
      -p|--password)   [ $# -ge 2 ] || die "для $1 нужен пароль"; GF_PASSWORD="$2"; shift 2 ;;
      --telegram-token) [ $# -ge 2 ] || die "для $1 нужен токен бота"; TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
      --telegram-chat)  [ $# -ge 2 ] || die "для $1 нужен id чата"; TELEGRAM_CHAT_ID="$2"; shift 2 ;;
      -y|--yes)        ASSUME_YES=1; shift ;;
      --systemd)       SYSTEMD_MODE="yes"; shift ;;
      --no-systemd)    SYSTEMD_MODE="no"; shift ;;
      --no-download)   DO_DOWNLOAD=0; shift ;;
      --no-start)      DO_START=0; shift ;;
      --uninstall)     DO_UNINSTALL=1; shift ;;
      --purge)         DO_PURGE=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      -V|--version)    printf 'install.sh v%s\n' "$INSTALLER_VERSION"; exit 0 ;;
      *)               die "неизвестный аргумент: $1  (справка: --help)" ;;
    esac
  done

  case "$INSTALL_DIR" in
    /*) : ;;
    *) die "каталог установки должен быть абсолютным путём: $INSTALL_DIR" ;;
  esac
  [ "$INSTALL_DIR" != "/" ] || die "каталог установки не может быть /"
  case "$INSTALL_DIR" in
    *" "*) die "в пути $INSTALL_DIR есть пробелы — systemd и run.sh не смогут с ним работать. Выберите путь без пробелов." ;;
  esac
}

# =====================================================================
#  Проверки окружения
# =====================================================================

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "нужны права root. Запустите одним из способов:
    curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/main/install.sh | sudo bash
    sudo bash /путь/к/install.sh"
  fi
}

preflight_deps() {
  local missing="" cmd
  for cmd in curl tar sed awk mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  if [ -n "$missing" ]; then
    die "не найдены обязательные программы:$missing
    Установите их, например:
      Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y curl tar sed gawk coreutils
      RHEL/Fedora:   sudo dnf install -y curl tar sed gawk coreutils
      Arch:          sudo pacman -S --needed curl tar sed gawk coreutils"
  fi
  if [ "$DO_DOWNLOAD" = 1 ] && ! command -v sha256sum >/dev/null 2>&1; then
    warn "sha256sum не найден — скачивание бинарников доверю run.sh (без проверки сумм)"
    DO_DOWNLOAD=0
  fi
}

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)    ARCH="linux-amd64" ;;
    aarch64|arm64)   ARCH="linux-arm64" ;;
    armv7l|armv7)    ARCH="linux-armv7" ;;
    armv6l|armv6)    ARCH="linux-armv6" ;;
    *) die "неизвестная архитектура '$m'. Поддерживаются: amd64, arm64, armv7, armv6." ;;
  esac
  info "архитектура: $m -> $ARCH"
}

resolve_systemd() {
  local pid1=""
  if [ -r /proc/1/comm ]; then
    pid1="$(cat /proc/1/comm 2>/dev/null || true)"
  fi
  case "$SYSTEMD_MODE" in
    yes)
      command -v systemctl >/dev/null 2>&1 || die "--systemd указан, но systemctl не найден"
      [ "$pid1" = "systemd" ] || warn "PID 1 = '$pid1', а не systemd — автозапуск может не сработать"
      SYSTEMD="yes"
      ;;
    no)
      SYSTEMD="no"
      ;;
    auto)
      if command -v systemctl >/dev/null 2>&1 && [ "$pid1" = "systemd" ]; then
        SYSTEMD="yes"
      else
        SYSTEMD="no"
      fi
      ;;
  esac
}

banner() {
  printf '%s\n' "${C_BOLD}UPS Monitoring — установка (native, без Docker)${C_RESET}" >&2
  printf '    репозиторий : %s @ %s\n' "$REPO_SLUG" "$REF" >&2
  printf '    каталог     : %s\n' "$INSTALL_DIR" >&2
  printf '    архитектура : %s\n' "$ARCH" >&2
  printf '    автозапуск  : %s\n' "$([ "$SYSTEMD" = yes ] && echo 'systemd' || echo 'нет (запуск вручную через run.sh)')" >&2
}

# =====================================================================
#  Остановка предыдущей установки
# =====================================================================

stop_existing() {
  if [ -f "$UNIT_FILE" ] && command -v systemctl >/dev/null 2>&1; then
    info "останавливаю ранее установленный сервис $SERVICE_NAME..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  if [ -x "$INSTALL_DIR/stop.sh" ]; then
    "$INSTALL_DIR/stop.sh" >/dev/null 2>&1 || true
  fi
  # даём процессам время освободить порты
  sleep 1
}

# =====================================================================
#  Мелкие утилиты
# =====================================================================

valid_target() {  # IPv4 или DNS-имя
  local t="$1" o a b c d
  # строка только из цифр и точек — значит, пытались ввести IPv4
  if [[ "$t" =~ ^[0-9.]+$ ]]; then
    [[ "$t" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<<"$t"
    for o in "$a" "$b" "$c" "$d"; do
      (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
    done
    return 0
  fi
  [[ "$t" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

# Убирает символы, ломающие YAML/конфиги. Для значений в targets.yml кавычки не нужны.
sanitize_text() {
  local s="$1"
  s="${s//\'/}"
  s="${s//\"/}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  printf '%s' "$s"
}

add_entry() {  # $1=ip $2=имя $3=расположение
  local ip="$1" name loc
  name="$(sanitize_text "${2-}")"
  loc="$(sanitize_text "${3-}")"
  valid_target "$ip" || return 1
  ENTRIES+=("$ip|$name|$loc")
}

# Разбирает --targets "IP[:ИМЯ[:РАСПОЛОЖЕНИЕ]],..."
parse_targets_spec() {
  local spec="$1" rec ip rest name loc
  local IFS=','
  for rec in $spec; do
    rec="${rec#"${rec%%[![:space:]]*}"}"   # trim слева
    rec="${rec%"${rec##*[![:space:]]}"}"   # trim справа
    [ -n "$rec" ] || continue
    ip="${rec%%:*}"
    if [ "$ip" = "$rec" ]; then rest=""; else rest="${rec#*:}"; fi
    name=""; loc=""
    if [ -n "$rest" ]; then
      name="${rest%%:*}"
      if [ "$name" != "$rest" ]; then loc="${rest#*:}"; fi
    fi
    if ! add_entry "$ip" "$name" "$loc"; then
      die "некорректный адрес ИБП в --targets: '$ip'
    Ожидается IPv4 или DNS-имя. Пример: --targets '192.168.1.10:UPS-01:Узел 1'"
    fi
  done
  [ "${#ENTRIES[@]}" -gt 0 ] || die "в --targets не разобрано ни одного адреса: '$spec'"
}

collect_targets_interactive() {
  local line ip name loc i=0
  info "Перечислите ИБП. Формат строки: <IP> [имя ИБП] [расположение]."
  info "Пустая строка — закончить ввод."
  while :; do
    printf '    ИБП #%d (IP): ' "$((i + 1))" >"$TTY"
    IFS= read -r line <"$TTY" || break
    [ -n "${line// /}" ] || break
    ip=""; name=""; loc=""
    read -r ip name loc <<<"$line" || true
    if ! add_entry "$ip" "$name" "$loc"; then
      warn "'$ip' не похож на IPv4-адрес или DNS-имя — попробуйте ещё раз"
      continue
    fi
    ok "'$ip' добавлен"
    i=$((i + 1))
  done
  if [ "${#ENTRIES[@]}" -eq 0 ]; then
    warn "ни одного ИБП не указано — targets.yml останется шаблоном, дашборд будет пустым"
  fi
}

generate_password() {
  # только символы, безопасные для .env и systemd EnvironmentFile
  local chars='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_%@!+='
  local pass="" i n idx
  n="${#chars}"
  for ((i = 0; i < 20; i++)); do
    idx=$(( (RANDOM * 32768 + RANDOM) % n ))
    pass+="${chars:idx:1}"
  done
  printf '%s' "$pass"
}

read_current_community() {
  local f="$INSTALL_DIR/snmp.yml"
  [ -f "$f" ] || return 0
  sed -n 's/^[[:space:]]*community:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f" | head -n 1
}

read_current_env_value() {  # $1 = имя переменной
  local f="$INSTALL_DIR/.env"
  [ -f "$f" ] || return 0
  sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*$/\1/p" "$f" | head -n 1
}

# =====================================================================
#  Сбор настроек (до изменения каталога установки)
# =====================================================================

plan_config() {
  local cur user old_user old_pass before

  # --- targets.yml: заполнять или сохранить существующий? ---
  if [ -f "$INSTALL_DIR/targets.yml" ]; then
    if [ -n "$TARGETS_SPEC" ]; then
      KEEP_TARGETS=0
    elif [ "$ASSUME_YES" = 1 ] || ! have_tty; then
      KEEP_TARGETS=1
    else
      info "найден существующий targets.yml"
      if prompt_yesno "Оставить текущий список ИБП?" y; then KEEP_TARGETS=1; else KEEP_TARGETS=0; fi
    fi
  fi

  if [ "$KEEP_TARGETS" = 0 ]; then
    if [ -n "$TARGETS_SPEC" ]; then
      parse_targets_spec "$TARGETS_SPEC"
    elif [ "$ASSUME_YES" = 0 ] && have_tty; then
      collect_targets_interactive
    fi
  fi

  # --- SNMP community ---
  cur="$(read_current_community)"
  [ -n "$cur" ] || cur="public"
  if [ -z "$COMMUNITY" ]; then
    if [ "$ASSUME_YES" = 0 ] && have_tty; then
      COMMUNITY="$(prompt "SNMP community" "$cur")"
    else
      COMMUNITY="$cur"
    fi
  fi
  [ -n "$COMMUNITY" ] || die "SNMP community не может быть пустым"
  if ! [[ "$COMMUNITY" =~ ^[A-Za-z0-9._@-]{1,32}$ ]]; then
    die "недопустимый SNMP community: '$COMMUNITY'
    Разрешены латиница, цифры и символы . _ @ - (до 32 символов)."
  fi

  # --- Grafana: логин/пароль ---
  old_user="$(read_current_env_value GRAFANA_ADMIN_USER)"
  old_pass="$(read_current_env_value GRAFANA_ADMIN_PASSWORD)"

  if [ -f "$INSTALL_DIR/.env" ]; then
    if [ -n "$GF_USER" ] || [ -n "$GF_PASSWORD" ]; then
      KEEP_ENV=0            # явно задали новые — применяем
    elif [ "$ASSUME_YES" = 1 ] || ! have_tty; then
      KEEP_ENV=1            # молча обновляемся — пароль не трогаем
    else
      info "найден существующий .env с учётными данными Grafana"
      if prompt_yesno "Оставить текущий логин/пароль Grafana?" y; then KEEP_ENV=1; else KEEP_ENV=0; fi
    fi
  fi

  if [ "$KEEP_ENV" = 0 ]; then
    if [ -z "$GF_USER" ]; then
      [ -n "$old_user" ] || old_user="admin"
      if [ "$ASSUME_YES" = 0 ] && have_tty; then
        GF_USER="$(prompt "логин администратора Grafana" "$old_user")"
      else
        GF_USER="$old_user"
      fi
    fi
    [ -n "$GF_USER" ] || die "логин Grafana не может быть пустым"

    if [ -z "$GF_PASSWORD" ]; then
      if [ -n "$old_pass" ]; then
        GF_PASSWORD="$old_pass"          # логин меняют — пароль сохраняем
      else
        GF_PASSWORD="$(generate_password)"
        GENERATED_PASSWORD=1
      fi
    fi

    if [ "$ASSUME_YES" = 0 ] && have_tty; then
      before="$GF_PASSWORD"
      GF_PASSWORD="$(prompt "пароль администратора Grafana" "$GF_PASSWORD")"
      [ "$GF_PASSWORD" = "$before" ] || GENERATED_PASSWORD=0
    fi
    validate_password "$GF_PASSWORD"
  fi

  validate_telegram "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID"
}

validate_password() {
  local p="$1"
  if [ "${#p}" -lt 8 ]; then
    die "пароль Grafana короче 8 символов"
  fi
  if ! [[ "$p" =~ ^[A-Za-z0-9._@%+=!:-]+$ ]]; then
    die "в пароле Grafana есть символы, которые нельзя записать в .env и systemd EnvironmentFile.
    Допустимы: латиница, цифры и . _ @ % + = ! : -
    Пример: --password 'Str0ng-P@ss'"
  fi
}

# Токен и id чата Telegram попадают в .env, который читается через
# `set -a; . .env`, поэтому опасные символы (пробелы, кавычки, #, $) недопустимы.
validate_telegram() {
  local t="$1" c="$2"
  if [ -n "$t" ] && ! [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    die "токен Telegram не похож на настоящий (ожидается вид 123456789:AA...).
    Получите токен у @BotFather и передайте: --telegram-token '123456789:AA...'"
  fi
  if [ -n "$c" ] && ! [[ "$c" =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]]; then
    die "id чата Telegram должен быть числом (для группы/канала — отрицательным,
    например -1001234567890) либо @имя_канала."
  fi
  if [ -n "$t" ] && [ -z "$c" ]; then
    warn "задан токен бота, но не задан --telegram-chat: уведомления не уйдут"
  fi
  if [ -z "$t" ] && [ -n "$c" ]; then
    warn "задан --telegram-chat, но не задан токен бота: уведомления не уйдут"
  fi
}

# =====================================================================
#  Загрузка и распаковка репозитория
# =====================================================================

stage_repo() {
  local url tarball top
  STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/upsmon-install.XXXXXX")"
  STAGE_DIR="$STAGE_ROOT"
  tarball="$STAGE_DIR/repo.tar.gz"
  url="https://github.com/${REPO_SLUG}/archive/refs/heads/${REF}.tar.gz"
  case "$REF" in
    v[0-9]*|[0-9]*) url="https://github.com/${REPO_SLUG}/archive/refs/tags/${REF}.tar.gz" ;;
  esac

  info "скачиваю ${REPO_SLUG}@${REF}..."
  curl -fsSL --retry 3 --connect-timeout 20 -o "$tarball" "$url" \
    || die "не удалось скачать $url (проверьте ветку/тег --ref и доступ в интернет)"

  tar -xzf "$tarball" -C "$STAGE_DIR" || die "не удалось распаковать архив репозитория"
  top="$(find "$STAGE_DIR" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
  [ -n "$top" ] || die "в архиве нет каталога с исходниками"

  rm -f "$tarball"
  STAGE_DIR="$top"

  # Обязательный минимум, который есть в любой версии проекта.
  # Остальное (status.sh, targets.yml, docs/, алерты) может отсутствовать
  # в старых версиях — устанавливаем то, что есть.
  for f in run.sh stop.sh prometheus.yml snmp.yml; do
    [ -f "$STAGE_DIR/$f" ] || die "в архиве репозитория нет файла $f — изменилась структура проекта?"
  done
  [ -f "$STAGE_DIR/targets.yml" ] || info "в этой версии нет targets.yml — файл будет создан"
}

install_files() {
  local f
  step "Раскладываю файлы в $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/grafana"

  for f in run.sh stop.sh status.sh prometheus.yml snmp.yml README.md ROADMAP.md CHANGELOG.md; do
    if [ -f "$STAGE_DIR/$f" ]; then cp -a "$STAGE_DIR/$f" "$INSTALL_DIR/$f"; fi
  done
  if [ -d "$STAGE_DIR/grafana" ]; then
    cp -a "$STAGE_DIR/grafana/." "$INSTALL_DIR/grafana/"
  fi
  # документация кладётся рядом, чтобы её можно было читать на сервере
  if [ -d "$STAGE_DIR/docs" ]; then
    mkdir -p "$INSTALL_DIR/docs"
    cp -a "$STAGE_DIR/docs/." "$INSTALL_DIR/docs/"
  fi

  # chmod только для того, что реально установилось (в старых версиях
  # status.sh может отсутствовать)
  for f in run.sh stop.sh status.sh; do
    if [ -f "$INSTALL_DIR/$f" ]; then chmod +x "$INSTALL_DIR/$f"; fi
  done
  ok "файлы обновлены"
}

# run.sh рассчитан на amd64 и не читает .env — правим это идемпотентно.
patch_run_sh() {
  local run="$INSTALL_DIR/run.sh" line

  if [ "$ARCH" != "linux-amd64" ]; then
    sed -i "s|^ARCH=\"linux-amd64\"\$|ARCH=\"$ARCH\"|" "$run"
    grep -q "^ARCH=\"$ARCH\"\$" "$run" \
      || die "не удалось подставить ARCH=\"$ARCH\" в run.sh — изменился формат скрипта.
    Правьте $run вручную или запустите установщик с --no-download."
    info "run.sh: архитектура -> $ARCH"
  fi

  # run.sh печатает «admin / admin», хотя реальный пароль берётся из .env — поправим сообщение.
  if ! grep -qF 'логин/пароль из .env' "$run"; then
    sed -i 's#(логин/пароль: admin / admin или из GRAFANA_ADMIN_\*)#(логин/пароль из .env: ${GRAFANA_ADMIN_USER:-admin})#' "$run"
    if grep -qF 'логин/пароль из .env' "$run"; then
      info "run.sh: сообщение о логине Grafana поправлено"
    else
      warn "run.sh: сообщение о логине Grafana не поправлено (не критично, пароль всё равно из .env)"
    fi
  fi

  if grep -qF '# >>> install.sh: .env >>>' "$run"; then
    info "run.sh: чтение .env уже добавлено"
    return 0
  fi

  line="$(grep -n '^cd "\$DIR"$' "$run" | head -n 1 | cut -d: -f1)"
  if [ -z "$line" ]; then
    warn "в run.sh не найдена строка 'cd \"\$DIR\"' — .env будет читаться только через systemd"
    return 0
  fi

  {
    head -n "$line" "$run"
    cat <<'SNIPPET'

# >>> install.sh: .env >>>
# Подхватываем настройки из .env (логин/пароль Grafana и прочее).
if [ -f "$DIR/.env" ]; then
  set -a
  . "$DIR/.env"
  set +a
fi
# <<< install.sh: .env <<<
SNIPPET
    tail -n "+$((line + 1))" "$run"
  } > "$run.new"
  mv "$run.new" "$run"
  chmod +x "$run"
  ok "run.sh: добавлено чтение .env"
}

configure_community() {
  local f="$INSTALL_DIR/snmp.yml" cur
  cur="$(read_current_community)"
  if [ "$cur" = "$COMMUNITY" ]; then
    info "snmp.yml: community уже '$COMMUNITY'"
    return 0
  fi
  sed -i "0,/^[[:space:]]*community:/s|^\([[:space:]]*community:\)[[:space:]].*|\1 $COMMUNITY|" "$f"
  [ "$(read_current_community)" = "$COMMUNITY" ] \
    || die "не удалось изменить community в snmp.yml — проверьте файл вручную"
  ok "snmp.yml: community -> $COMMUNITY"
}

write_targets() {
  local f="$INSTALL_DIR/targets.yml" e ip name loc

  if [ "$KEEP_TARGETS" = 1 ]; then
    info "targets.yml: оставляю существующий"
    return 0
  fi

  {
    printf '# =====================================================================\n'
    printf '# СПИСОК ИБП ДЛЯ ОПРОСА\n'
    printf '# =====================================================================\n'
    printf '# Создано install.sh %s.\n' "$(date +%Y-%m-%d)"
    printf '#\n'
    printf '# Формат записи:\n'
    printf '#   - targets:\n'
    printf '#       - <IP-адрес ИБП>\n'
    printf '#     labels:\n'
    printf '#       ups_name: <имя на дашборде>\n'
    printf '#       location: <расположение>\n'
    printf '#\n'
    printf '# Дополнительно (необязательно): snmp_auth — имя блока auths из snmp.yml\n'
    printf '# для устройств с другим community или SNMP v3; snmp_module — имя модуля.\n'
    printf '#\n'
    printf '# Prometheus перечитывает файл каждые 30 секунд, перезапуск не нужен.\n'
    printf '# =====================================================================\n'
    printf '\n'

    if [ "${#ENTRIES[@]}" -eq 0 ]; then
      printf '# Добавьте свои ИБП вместо примера ниже.\n'
      printf -- '- targets:\n'
      printf '    - 192.168.1.10\n'
      printf '  labels:\n'
      printf "    ups_name: 'UPS-01'\n"
      printf "    location: 'Коммутационный узел №1'\n"
      return 0
    fi

    for e in "${ENTRIES[@]}"; do
      ip="${e%%|*}"; e="${e#*|}"
      name="${e%%|*}"; loc="${e#*|}"
      printf -- '- targets:\n'
      printf '    - %s\n' "$ip"
      if [ -n "$name" ] || [ -n "$loc" ]; then
        printf '  labels:\n'
        [ -n "$name" ] && printf "    ups_name: '%s'\n" "$name"
        [ -n "$loc" ] && printf "    location: '%s'\n" "$loc"
      fi
      printf '\n'
    done
  } > "$f"
  ok "targets.yml: записей — ${#ENTRIES[@]}"
}

write_env() {
  local f="$INSTALL_DIR/.env"
  if [ "$KEEP_ENV" = 1 ]; then
    info ".env: оставляю существующий"
    # Недостающие ключи (например, Telegram для алертов) дописывает
    # ensure_env_keys — чтобы обновление старых установок тоже их получило.
    return 0
  fi
  ( umask 077; cat > "$f" <<EOF
# Создано install.sh $(date +%Y-%m-%d).
GRAFANA_ADMIN_USER=$GF_USER
GRAFANA_ADMIN_PASSWORD=$GF_PASSWORD

# --- Алерты: уведомления в Telegram ---
# TELEGRAM_BOT_TOKEN — токен бота от @BotFather.
# TELEGRAM_CHAT_ID   — id чата/канала (для группы/канала отрицательный).
# Пока пусто — правила алертов работают, но уведомления не отправляются.
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF
  )
  chmod 600 "$f"
  ok ".env: логин Grafana '$GF_USER'"
}

# Приводит .env к актуальному виду, не затирая уже сохранённые значения:
#  - отсутствующие ключи дописывает (обновление старых установок);
#  - существующие ключи обновляет, только если новое значение задано явно.
ensure_env_keys() {
  local f="$INSTALL_DIR/.env" key val cur block="" changed=0
  [ -f "$f" ] || return 0
  for key in TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
    val="${!key}"
    if grep -qE "^[[:space:]]*${key}=" "$f"; then
      [ -n "$val" ] || continue                     # не задавали — оставляем как есть
      cur="$(read_current_env_value "$key")"
      [ "$cur" = "$val" ] && continue
      sed -i "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$f"
      changed=1
    else
      block="${block}${key}=${val}"$'\n'
      changed=1
    fi
  done
  [ "$changed" = 1 ] || return 0
  if [ -n "$block" ]; then
    {
      printf '\n# --- Алерты: уведомления в Telegram (добавлено install.sh) ---\n'
      printf '%s' "$block"
    } >> "$f"
  fi
  chmod 600 "$f"
  ok ".env: ключи Telegram для алертов обновлены"
}

# =====================================================================
#  Бинарники: скачивание с проверкой sha256
# =====================================================================
#  Версии берём из run.sh, чтобы не было расхождений с апстримом.
#  Если что-то пойдёт не так — run.sh всё равно скачает бинарники сам.

read_version() {  # $1 = имя переменной в run.sh
  local v
  v="$(sed -n "s/^$1=\"\([^\"]*\)\".*/\1/p" "$INSTALL_DIR/run.sh" | head -n 1)"
  [ -n "$v" ] || die "не удалось определить версию $1 в run.sh — изменился формат скрипта"
  printf '%s' "$v"
}

rel_url() {  # $1 = snmp|prom|grafana
  case "$1" in
    snmp) printf 'https://github.com/prometheus/snmp_exporter/releases/download/v%s/snmp_exporter-%s.%s.tar.gz' "$SNMP_VER" "$SNMP_VER" "$ARCH" ;;
    prom) printf 'https://github.com/prometheus/prometheus/releases/download/v%s/prometheus-%s.%s.tar.gz' "$PROM_VER" "$PROM_VER" "$ARCH" ;;
    graf) printf 'https://dl.grafana.com/oss/release/grafana-%s.%s.tar.gz' "$GF_VER" "$ARCH" ;;
  esac
}

rel_sums_url() {  # $1 = snmp|prom|grafana
  case "$1" in
    snmp) printf 'https://github.com/prometheus/snmp_exporter/releases/download/v%s/sha256sums.txt' "$SNMP_VER" ;;
    prom) printf 'https://github.com/prometheus/prometheus/releases/download/v%s/sha256sums.txt' "$PROM_VER" ;;
    graf) printf 'https://dl.grafana.com/oss/release/grafana-%s.%s.tar.gz.sha256' "$GF_VER" "$ARCH" ;;
  esac
}

rel_topdir() {  # каталог в архиве; run.sh ждёт ровно такие имена в bin/
  case "$1" in
    snmp) printf 'snmp_exporter-%s.%s' "$SNMP_VER" "$ARCH" ;;
    prom) printf 'prometheus-%s.%s' "$PROM_VER" "$ARCH" ;;
    graf) printf 'grafana-v%s' "$GF_VER" ;;
  esac
}

rel_probe() {  # путь внутри каталога, по которому run.sh определяет «уже скачано»
  case "$1" in
    snmp) printf 'snmp_exporter' ;;
    prom) printf 'prometheus' ;;
    graf) printf 'bin/grafana' ;;
  esac
}

rel_name() {
  case "$1" in
    snmp) printf 'snmp_exporter' ;;
    prom) printf 'prometheus' ;;
    graf) printf 'grafana' ;;
  esac
}

# Достаёт ожидаемую сумму из sha256sums.txt (mode=sums) или из *.sha256 (mode=sha)
expected_sha() {
  local sums_url="$1" mode="$2" wanted="$3" tmp line
  tmp="$(mktemp)"
  if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp" "$sums_url" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  case "$mode" in
    sums) line="$(grep -F "$wanted" "$tmp" 2>/dev/null | head -n 1 || true)"
          printf '%s' "${line%% *}" ;;
    sha)  grep -oE '[0-9a-fA-F]{64}' "$tmp" 2>/dev/null | head -n 1 || true ;;
  esac
  rm -f "$tmp"
}

fetch_and_extract() {
  local comp="$1" url="$2" sums_url="$3" mode="$4" dest="$5" topdir="$6"
  local name tmp file expected actual

  name="$(rel_name "$comp")"
  file="$(basename "$url")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/upsmon-dl.XXXXXX")"

  info "скачиваю $name ($file)..."
  if ! curl -fL --retry 3 --connect-timeout 20 -# -o "$tmp/$file" "$url"; then
    rm -rf "$tmp"
    die "не удалось скачать $name: $url
    Возможно, для архитектуры $ARCH нет сборки этой версии.
    Варианты: --no-download (пусть качает run.sh) или --ref с другой версией."
  fi

  expected="$(expected_sha "$sums_url" "$mode" "$file")"
  if [ -z "$expected" ]; then
    rm -rf "$tmp"
    die "не удалось получить контрольную сумму для $file ($sums_url)"
  fi
  actual="$(sha256sum "$tmp/$file" | awk '{print $1}')"
  if [ "$expected" != "$actual" ]; then
    rm -rf "$tmp"
    die "контрольная сумма $file не совпала!
    ожидалось: $expected
    получено:  $actual"
  fi
  ok "$name: sha256 проверена"

  tar -xzf "$tmp/$file" -C "$tmp" || { rm -rf "$tmp"; die "не удалось распаковать $file"; }
  if [ ! -d "$tmp/$topdir" ]; then
    rm -rf "$tmp"
    die "в архиве $file нет каталога $topdir (изменилась структура релиза)"
  fi
  rm -rf "${dest:?}/$topdir"
  mv "$tmp/$topdir" "$dest/"
  rm -rf "$tmp"
  ok "$name установлен в $dest/$topdir"
}

seed_binaries() {
  local comp url code
  SNMP_VER="$(read_version SNMP_VER)"
  PROM_VER="$(read_version PROM_VER)"
  GF_VER="$(read_version GF_VER)"

  step "Скачиваю бинарники ($ARCH)"
  info "версии из run.sh: snmp_exporter $SNMP_VER, Prometheus $PROM_VER, Grafana $GF_VER"

  # Проверяем, что сборки под нашу архитектуру вообще существуют.
  # Ответ 404 — повод остановиться сразу; сетевые сбои игнорируем (дальше всё равно скачивание).
  for comp in snmp prom graf; do
    url="$(rel_url "$comp")"
    code="$(curl -sIL --retry 3 --connect-timeout 20 -o /dev/null -w '%{http_code}' "$url" || true)"
    case "$code" in
      200) : ;;
      404|410)
        die "$(rel_name "$comp"): сборка для $ARCH не найдена (HTTP $code)
    $url
    Варианты: --no-download (пусть качает run.sh) или --ref с другой версией." ;;
      *)
        warn "$(rel_name "$comp"): не удалось проверить доступность (HTTP $code) — пробую скачать" ;;
    esac
  done

  mkdir -p "$INSTALL_DIR/bin"
  for comp in snmp prom graf; do
    if [ -x "$INSTALL_DIR/bin/$(rel_topdir "$comp")/$(rel_probe "$comp")" ]; then
      info "$(rel_name "$comp"): уже скачан, пропускаю"
      continue
    fi
    case "$comp" in
      graf) fetch_and_extract "$comp" "$(rel_url "$comp")" "$(rel_sums_url "$comp")" sha "$INSTALL_DIR/bin" "$(rel_topdir "$comp")" ;;
      *)    fetch_and_extract "$comp" "$(rel_url "$comp")" "$(rel_sums_url "$comp")" sums "$INSTALL_DIR/bin" "$(rel_topdir "$comp")" ;;
    esac
  done
}

# =====================================================================
#  Порты и запуск
# =====================================================================

port_busy() {  # $1 = номер порта
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}\$" && return 0
    return 1
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

check_ports() {
  local busy="" p
  for p in 9116 9090 3000; do
    if port_busy "$p"; then busy="$busy $p"; fi
  done
  if [ -n "$busy" ]; then
    warn "порты заняты другими процессами:$busy"
    warn "сервисы на этих портах не поднимутся. Освободите порты и перезапустите:"
    warn "  systemctl restart $SERVICE_NAME   (или $INSTALL_DIR/run.sh)"
  fi
}

install_systemd() {
  step "Ставлю systemd-юнит $SERVICE_NAME"

  if grep -q -- '--foreground' "$INSTALL_DIR/run.sh" 2>/dev/null; then
    # Новый run.sh умеет режим супервизора: держит три сервиса, перезапускает
    # упавшие и завершается по сигналу systemd. StartLimit* — в [Unit]
    # (так требует systemd начиная с v230).
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=UPS monitoring (snmp_exporter + Prometheus + Grafana)
Documentation=https://github.com/${REPO_SLUG}
Documentation=file://${INSTALL_DIR}/README.md
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/run.sh --foreground
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
KillMode=mixed
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  else
    # Старая версия run.sh (до 1.1.0): она только запускает сервисы в фоне.
    # Такой юнит работает, но не заметит падения сервиса — обновление до
    # актуальной версии это лечит.
    warn "run.sh этой версии без режима супервизора: автоперезапуск при падении работать не будет"
    warn "  (подробности — CHANGELOG.md, версия 1.1.0)"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=UPS monitoring (snmp_exporter + Prometheus + Grafana)
Documentation=https://github.com/${REPO_SLUG}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/run.sh
ExecStop=${INSTALL_DIR}/stop.sh
TimeoutStartSec=900
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
  fi

  chmod 644 "$UNIT_FILE"
  systemctl daemon-reload
  if systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
    ok "автозапуск включён ($UNIT_FILE)"
  else
    warn "не удалось включить автозапуск — проверьте: systemctl enable $SERVICE_NAME"
  fi
}

# Логи сервисов пишутся в data/*.log и не должны расти бесконечно.
# copytruncate нужен потому, что процессы держат файлы открытыми.
install_logrotate() {
  local cfg="/etc/logrotate.d/${SERVICE_NAME}"
  if [ ! -d /etc/logrotate.d ]; then
    info "logrotate не установлен — логи в ${INSTALL_DIR}/data/*.log ротируются вручную"
    return 0
  fi
  step "Настраиваю ротацию логов ($cfg)"
  cat > "$cfg" <<EOF
${INSTALL_DIR}/data/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
  chmod 644 "$cfg"
  ok "логи в ${INSTALL_DIR}/data/*.log: неделя x 8, с сжатием"
}

start_stack() {
  step "Запускаю сервисы"
  if [ "$SYSTEMD" = yes ]; then
    if systemctl restart "$SERVICE_NAME"; then
      ok "сервис $SERVICE_NAME запущен"
    else
      warn "systemctl restart вернул ошибку, смотрите: journalctl -u $SERVICE_NAME -n 50"
    fi
  else
    "$INSTALL_DIR/run.sh" || warn "run.sh вернул ошибку, смотрите логи в $INSTALL_DIR/data/*.log"
  fi
}

wait_http() {  # $1 = url, $2 = имя, $3 = таймаут в секундах
  local url="$1" name="$2" timeout="$3" i=0
  while [ "$i" -lt "$timeout" ]; do
    if curl -fsS -o /dev/null --max-time 3 "$url" 2>/dev/null; then
      ok "$name отвечает"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  warn "$name не ответил за ${timeout}s"
  return 1
}

# Проверяет, что Grafana действительно загрузила правила алертов из провижининга:
# ошибка в YAML не роняет Grafana — правила просто не появятся, и отказ ИБП
# останется незамеченным.
check_alert_rules() {
  local user pass count
  # в версиях до 1.1.0 правила алертов не поставлялись
  [ -d "$INSTALL_DIR/grafana/provisioning/alerting" ] || return 0
  user="$(read_current_env_value GRAFANA_ADMIN_USER)"
  [ -n "$user" ] || user="${GF_USER:-admin}"
  pass="$(read_current_env_value GRAFANA_ADMIN_PASSWORD)"
  [ -n "$pass" ] || pass="${GF_PASSWORD:-}"
  if [ -z "$pass" ]; then
    warn "не проверяю правила алертов: пароль Grafana неизвестен"
    return 0
  fi
  count="$(curl -fsS -u "$user:$pass" --max-time 15 \
             'http://127.0.0.1:3000/api/v1/provisioning/alert-rules' 2>/dev/null \
             | grep -o '"uid"' | wc -l)"
  if [ "${count:-0}" -gt 0 ]; then
    ok "правила алертов загружены: ${count} шт. (Grafana -> Alerting -> папка UPS)"
    if [ -n "$(read_current_env_value TELEGRAM_BOT_TOKEN)" ] \
       && [ -n "$(read_current_env_value TELEGRAM_CHAT_ID)" ]; then
      ok "уведомления: Telegram включён"
    else
      info "уведомления выключены (по умолчанию) — алерты видны только в Grafana"
      info "  включить: TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID в $INSTALL_DIR/.env и перезапустить"
    fi
  else
    warn "правила алертов не найдены — проверьте grafana/provisioning/alerting/rules.yml"
    warn "  и лог: $INSTALL_DIR/data/grafana.log"
  fi
}

health_check() {
  local fails=0 first_ip="" e
  step "Проверяю, что всё поднялось"

  wait_http "http://127.0.0.1:9116/" "snmp_exporter" 30 || fails=$((fails + 1))
  wait_http "http://127.0.0.1:9090/-/healthy" "Prometheus" 60 || fails=$((fails + 1))
  wait_http "http://127.0.0.1:3000/api/health" "Grafana" 90 || fails=$((fails + 1))

  check_alert_rules

  if [ "${#ENTRIES[@]}" -gt 0 ]; then
    for e in "${ENTRIES[@]}"; do first_ip="${e%%|*}"; break; done
  fi
  if [ -n "$first_ip" ]; then
    info "опрашиваю ИБП $first_ip по SNMP (может занять до 20 с)..."
    if curl -fsS --max-time 20 "http://127.0.0.1:9116/snmp?module=ups&target=${first_ip}" 2>/dev/null \
         | grep -q '^ups'; then
      ok "ИБП $first_ip отвечает по SNMP"
    else
      warn "ИБП $first_ip не ответил по SNMP. Проверьте:"
      warn "  - ИБП доступен по UDP 161 (community '$COMMUNITY', SNMP включён в веб-интерфейсе ИБП)"
      warn "  - вручную: curl 'http://127.0.0.1:9116/snmp?module=ups&target=${first_ip}'"
    fi
  fi

  if [ "$fails" -gt 0 ]; then
    warn "часть сервисов не поднялась — логи: $INSTALL_DIR/data/*.log"
    if [ "$SYSTEMD" = yes ]; then
      warn "журнал: journalctl -u $SERVICE_NAME -n 50 --no-pager"
    fi
  fi
}

# =====================================================================
#  Итоговая сводка
# =====================================================================

local_ip() {
  local ip=""
  if command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
          | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  fi
  if [ -z "$ip" ]; then ip="$(hostname 2>/dev/null || true)"; fi
  printf '%s' "$ip"
}

print_summary() {
  local ip user pass
  ip="$(local_ip || true)"
  [ -n "$ip" ] || ip="<IP-сервера>"

  if [ "$KEEP_ENV" = 1 ]; then
    user="$(read_current_env_value GRAFANA_ADMIN_USER)"
    [ -n "$user" ] || user="admin"
    pass="$(read_current_env_value GRAFANA_ADMIN_PASSWORD)"
  else
    user="$GF_USER"
    pass="$GF_PASSWORD"
  fi

  printf '\n%s─────────────────────────────────────────────────────────%s\n' "$C_BOLD" "$C_RESET" >&2
  printf '%sГотово.%s\n\n' "$C_GREEN$C_BOLD" "$C_RESET" >&2
  printf '  Grafana        http://%s:3000\n' "$ip" >&2
  printf '  Prometheus     http://%s:9090\n' "$ip" >&2
  printf '  snmp_exporter  http://%s:9116\n\n' "$ip" >&2
  printf '  Логин Grafana  %s\n' "$user" >&2
  printf '  Пароль Grafana %s%s%s\n' "$C_BOLD" "$pass" "$C_RESET" >&2
  if [ "$GENERATED_PASSWORD" = 1 ]; then
    printf '  %s↑ пароль сгенерирован установщиком — сохраните его%s\n' "$C_YELLOW" "$C_RESET" >&2
  fi
  printf '  (файл %s/.env, доступен только root)\n\n' "$INSTALL_DIR" >&2

  printf '  Список ИБП     %s/targets.yml\n' "$INSTALL_DIR" >&2
  printf '  Версия         %s   (другая: install.sh --ref v1.0.0 | --ref main)\n' "$REF" >&2
  printf '  История версий %s/CHANGELOG.md (список версий и что менялось)\n' "$INSTALL_DIR" >&2
  if [ -d "$INSTALL_DIR/grafana/provisioning/alerting" ]; then
    printf '  Алерты         Grafana -> Alerting -> папка UPS (7 правил)\n' >&2
    if [ -n "$(read_current_env_value TELEGRAM_BOT_TOKEN)" ] \
       && [ -n "$(read_current_env_value TELEGRAM_CHAT_ID)" ]; then
      printf '  Уведомления    Telegram включён\n' >&2
    else
      printf '  Уведомления    выключены (по умолчанию) — алерты видны в Grafana\n' >&2
      printf '                 включить: TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID в %s/.env\n' "$INSTALL_DIR" >&2
    fi
  else
    printf '  Алерты         в этой версии нет (появились в 1.1.0)\n' >&2
  fi
  printf '  Логи           %s/data/*.log\n' "$INSTALL_DIR" >&2
  printf '  Обновить       заново запустить install.sh (настройки сохранятся)\n' >&2

  if [ "$SYSTEMD" = yes ]; then
    printf '  Управление     systemctl {status|stop|start|restart} %s\n' "$SERVICE_NAME" >&2
  else
    printf '  Управление     %s/run.sh  и  %s/stop.sh\n' "$INSTALL_DIR" "$INSTALL_DIR" >&2
  fi
  if [ "$SELF_PIPED" = 1 ]; then
    printf '  Удалить        install.sh --uninstall [--purge]  (тем же способом, каким ставили)\n' >&2
  else
    printf '  Удалить        sudo %s --uninstall [--purge]\n' "$SELF_CMD" >&2
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    printf '\n  %sufw активен%s — для доступа к Grafana извне откройте порт 3000:\n' "$C_YELLOW" "$C_RESET" >&2
    printf '    ufw allow from <ваша сеть> to any port 3000 proto tcp\n' >&2
    printf '    (порты 9090 и 9116 наружу открывать не нужно — см. README)\n' >&2
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    printf '\n  %sfirewalld активен%s — для доступа к Grafana извне откройте порт 3000:\n' "$C_YELLOW" "$C_RESET" >&2
    printf '    firewall-cmd --permanent --add-port=3000/tcp && firewall-cmd --reload\n' >&2
    printf '    (порты 9090 и 9116 наружу открывать не нужно — см. README)\n' >&2
  fi
  printf '\n' >&2
}

# =====================================================================
#  Удаление
# =====================================================================

do_uninstall() {
  step "Удаление"
  if [ -f "$UNIT_FILE" ]; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "systemd-юнит удалён"
  else
    info "systemd-юнит не найден"
  fi

  if [ -x "$INSTALL_DIR/stop.sh" ]; then
    "$INSTALL_DIR/stop.sh" >/dev/null 2>&1 || true
    ok "процессы остановлены"
  fi

  if [ -f "/etc/logrotate.d/${SERVICE_NAME}" ]; then
    rm -f "/etc/logrotate.d/${SERVICE_NAME}"
    ok "правило ротации логов удалено"
  fi

  if [ "$DO_PURGE" = 1 ]; then
    rm -rf "$INSTALL_DIR"
    ok "каталог $INSTALL_DIR удалён (вместе с данными Prometheus и Grafana)"
  else
    info "каталог $INSTALL_DIR оставлен (данные и настройки не тронуты)"
    if [ "$SELF_PIPED" = 1 ]; then
      info "полное удаление: install.sh --uninstall --purge (тем же способом)   или   rm -rf $INSTALL_DIR"
    else
      info "полное удаление: sudo $SELF_CMD --uninstall --purge   или   rm -rf $INSTALL_DIR"
    fi
  fi
}

# =====================================================================
#  main
# =====================================================================

cleanup() {
  [ -n "${STAGE_ROOT:-}" ] && rm -rf "$STAGE_ROOT" 2>/dev/null || true
}

main() {
  parse_args "$@"
  require_root

  # Как ссылаться на этот скрипт в подсказках: при `curl | bash` файла на диске нет,
  # а ${BASH_SOURCE[0]} внутри функции подставляется как «bash».
  if [ -f "${BASH_SOURCE[0]:-/nonexistent}" ]; then
    SELF_CMD="${BASH_SOURCE[0]}"
    SELF_PIPED=0
  else
    SELF_PIPED=1
  fi

  if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR существует и не является каталогом"
  fi

  if [ "$DO_UNINSTALL" = 1 ]; then
    trap cleanup EXIT
    do_uninstall
    exit 0
  fi

  # Версия, которой обновляемся. Если --ref не указан, а система уже стояла —
  # остаёмся на той же версии: обновление не «уезжает» на main само по себе.
  if [ "$REF_GIVEN" = 0 ] && [ -f "$INSTALL_DIR/.installed-ref" ]; then
    remembered="$(head -n 1 "$INSTALL_DIR/.installed-ref" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$remembered" ]; then
      REF="$remembered"
      info "версия из прошлой установки: $REF (сменить: --ref v1.1.0 или --ref main)"
    fi
  fi

  trap cleanup EXIT
  preflight_deps
  detect_arch
  resolve_systemd
  banner

  plan_config

  step "Останавливаю предыдущую установку (если была)"
  stop_existing
  ok "готово"

  stage_repo
  install_files
  # запоминаем версию, чтобы при следующем запуске без --ref остаться на ней
  printf '%s\n' "$REF" > "$INSTALL_DIR/.installed-ref"
  patch_run_sh
  configure_community
  write_targets
  write_env
  ensure_env_keys

  if [ "$DO_DOWNLOAD" = 1 ]; then
    seed_binaries
  else
    info "бинарники скачает run.sh при первом запуске"
  fi

  check_ports

  if [ "$SYSTEMD" = yes ]; then
    install_systemd
  else
    info "systemd не используется — запуск вручную: $INSTALL_DIR/run.sh"
  fi

  install_logrotate

  if [ "$DO_START" = 1 ]; then
    start_stack
    health_check
  else
    info "--no-start: сервисы не запускались"
  fi

  print_summary
}

# Запускаем при исполнении (в том числе через `curl | bash`), но не при `source`.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
