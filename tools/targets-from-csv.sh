#!/usr/bin/env bash
# =====================================================================
#  UPS Monitoring (native) — targets.yml из инвентаря
# =====================================================================
#  Собирает список ИБП (targets.yml) из простой таблицы: удобно, когда
#  устройств много и список ведётся в Excel/NetBox/CMDB.
#
#  Формат файла инвентаря (разделитель — точка с запятой):
#      # строки, начинающиеся с #, игнорируются
#      192.168.1.10;UPS-01;Узел №1
#      10.0.0.5;UPS-DC1;ЦОД-1;dc_v3          # своя учётка (snmp_auth)
#      10.0.0.6;UPS-DC2;ЦОД-1;;ups_vendor    # свой модуль (snmp_module)
#
#  Поля: IP[:порт];имя;расположение[;snmp_auth[;snmp_module]]
#  Имя (ups_name) должно быть уникальным — оно становится меткой instance.
#
#  Использование:
#      tools/targets-from-csv.sh inventory.csv            # записать targets.yml
#      tools/targets-from-csv.sh inventory.csv --check     # только проверить
#      tools/targets-from-csv.sh inventory.csv -o /path/targets.yml
#
#  Пример инвентаря: tools/inventory.example.csv
#  После записи Prometheus подхватит файл в течение ~30 секунд,
#  перезапуск не нужен.
# =====================================================================
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

CSV=""
OUT="$PROJECT_DIR/targets.yml"
CHECK=0

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

die() { printf 'ошибка: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUT="${2:-}"; shift ;;
    --check)     CHECK=1 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "неизвестный аргумент: $1 (справка: --help)" ;;
    *)           [ -z "$CSV" ] || die "указано больше одного файла инвентаря"; CSV="$1" ;;
  esac
  shift
done

[ -n "$CSV" ] || die "не указан файл инвентаря (пример: tools/targets-from-csv.sh inventory.csv)"
[ -f "$CSV" ] || die "файл не найден: $CSV"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# IP или DNS-имя, необязательно с портом (например 10.0.0.5:1161)
valid_target() {
  local t="$1" host="" port="" o
  if [ "${t#*:}" != "$t" ]; then
    host="${t%%:*}"
    port="${t##*:}"
    [ -n "$host" ] || return 1
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    t="$host"
  fi

  if [[ "$t" =~ ^[0-9.]+$ ]]; then
    [[ "$t" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS=.
    for o in $t; do
      [ "$((10#$o))" -le 255 ] || return 1
    done
    return 0
  fi
  [[ "$t" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

yaml_quote() { printf "%s" "${1//\'/\'\'}"; }

tmp_body="$(mktemp)"
trap 'rm -f "$tmp_body"' EXIT

declare -A seen_ip=() seen_name=()
count=0
errors=0
line_no=0

while IFS=';' read -r ip name loc auth mod || [ -n "${ip:-}" ]; do
  line_no=$((line_no + 1))
  ip="$(trim "${ip:-}")"
  name="$(trim "${name:-}")"
  loc="$(trim "${loc:-}")"
  auth="$(trim "${auth:-}")"
  mod="$(trim "${mod:-}")"

  case "$ip" in ''|'#'*) continue ;; esac

  if ! valid_target "$ip"; then
    printf '  строка %d: «%s» не похоже на IP или DNS-имя\n' "$line_no" "$ip" >&2
    errors=$((errors + 1))
    continue
  fi
  if [ -n "${seen_ip[$ip]:-}" ]; then
    printf '  строка %d: адрес %s уже есть выше\n' "$line_no" "$ip" >&2
    errors=$((errors + 1))
    continue
  fi
  if [ -n "$name" ] && [ -n "${seen_name[$name]:-}" ]; then
    printf '  строка %d: имя «%s» уже занято (имена должны быть уникальны)\n' "$line_no" "$name" >&2
    errors=$((errors + 1))
    continue
  fi

  seen_ip[$ip]=1
  [ -n "$name" ] && seen_name[$name]=1

  {
    printf -- '- targets:\n'
    printf '    - %s\n' "$ip"
    if [ -n "$name" ] || [ -n "$loc" ] || [ -n "$auth" ] || [ -n "$mod" ]; then
      printf '  labels:\n'
      [ -n "$name" ] && printf "    ups_name: '%s'\n" "$(yaml_quote "$name")"
      [ -n "$loc" ]  && printf "    location: '%s'\n" "$(yaml_quote "$loc")"
      [ -n "$auth" ] && printf "    snmp_auth: '%s'\n" "$(yaml_quote "$auth")"
      [ -n "$mod" ]  && printf "    snmp_module: '%s'\n" "$(yaml_quote "$mod")"
    fi
    printf '\n'
  } >> "$tmp_body"

  count=$((count + 1))
done < "$CSV"

if [ "$errors" -gt 0 ]; then
  die "в инвентаре $errors ошибок — файл не изменён"
fi
[ "$count" -gt 0 ] || die "в инвентаре нет ни одного устройства"

printf 'проверено устройств: %d\n' "$count"

if [ "$CHECK" = 1 ]; then
  printf 'режим --check: %s не изменён\n' "$OUT"
  exit 0
fi

{
  printf '# =====================================================================\n'
  printf '# СПИСОК ИБП ДЛЯ ОПРОСА\n'
  printf '# =====================================================================\n'
  printf '# Создано tools/targets-from-csv.sh %s из файла %s\n' "$(date +%Y-%m-%d)" "$CSV"
  printf '#\n'
  printf '# Формат записи и все метки: docs/configuration.md\n'
  printf '# Prometheus перечитывает файл каждые 30 секунд, перезапуск не нужен.\n'
  printf '# =====================================================================\n'
  printf '\n'
  cat "$tmp_body"
} > "${OUT}.new"

mv "${OUT}.new" "$OUT"
printf 'записано в %s (устройств: %d)\n' "$OUT" "$count"
printf 'проверить: %s/status.sh — и через ~30 с данные появятся в Prometheus\n' "$PROJECT_DIR"
