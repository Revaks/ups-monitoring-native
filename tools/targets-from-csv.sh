#!/usr/bin/env bash
# =====================================================================
#  UPS Monitoring (native) — targets.yml из инвентаря
# =====================================================================
#  Собирает список ИБП (targets.yml) из простой таблицы: удобно, когда
#  устройств много и список ведётся в Excel/NetBox/CMDB.
#
#  Формат файла инвентаря (разделитель — точка с запятой).
#  Строки, начинающиеся с #, игнорируются.
#
#  1) С шапкой (рекомендуется: колонки можно переставлять и указывать
#     не все, обязательна только ip):
#
#         ip;site;name;location;snmp_auth
#         192.168.1.10;Площадка №1;UPS-01;Узел №1
#         10.0.0.5;ЦОД-1;UPS-DC1;ЦОД-1, ряд 3;dc_v3
#
#     Имена колонок: ip, site, name, location, snmp_auth, snmp_module.
#     Синонимы: адрес, площадка/территория, имя, расположение, community.
#
#  2) Без шапки (как было раньше) — позиции фиксированы:
#
#         IP[:порт];имя;расположение[;snmp_auth[;snmp_module[;site]]]
#
#  Поля:
#    ip          — IP или DNS-имя, можно с портом (10.0.0.5:1161);
#    site        — территория/площадка: по ней группы подразделений видят
#                  только свои ИБП (см. docs/access.md). Пишите одинаково
#                  у всех ИБП одной территории;
#    name        — ups_name, имя на дашборде (должно быть уникальным!);
#    location    — расположение / узел;
#    snmp_auth   — имя блока из snmp.yml, если у устройства другой community
#                  или SNMP v3;
#    snmp_module — имя модуля из snmp.yml, если нужен другой набор OID.
#
#  Использование:
#      tools/targets-from-csv.sh inventory.csv            # записать targets.yml
#      tools/targets-from-csv.sh inventory.csv --check     # только проверить
#      tools/targets-from-csv.sh inventory.csv -o /path/targets.yml
#
#  ВНИМАНИЕ: targets.yml перезаписывается целиком. Если вы правили его руками,
#  перенесите правки в инвентарь — иначе они потеряются. Метки, которых нет
#  в инвентаре (например site), в новый файл не попадут.
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

# ------------------------------------------------------------------ колонки
# Имя колонки из шапки -> внутреннее имя. Ключи в нижнем регистре.
declare -A COLNAME=(
  [ip]=ip [адрес]=ip [target]=ip [целевой]=ip
  [site]=site [площадка]=site [территория]=site [филиал]=site
  [name]=name [ups_name]=name [имя]=name
  [location]=location [расположение]=location [узел]=location
  [snmp_auth]=snmp_auth [auth]=snmp_auth [community]=snmp_auth [учётка]=snmp_auth
  [snmp_module]=snmp_module [module]=snmp_module [модуль]=snmp_module
)

norm_col() {
  # Убирает CR (файлы из Windows), пробелы по краям, BOM и приводит к нижнему регистру
  local s="${1:-}"
  s="${s%$'\r'}"
  s="${s#$'\xEF\xBB\xBF'}"
  s="$(trim "$s")"
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]'
}

# Индекс колонки; пустая строка = колонки нет
IDX_IP=0 IDX_NAME=1 IDX_LOC=2 IDX_AUTH=3 IDX_MOD=4 IDX_SITE=""
HEADER_LINE=0

# Ищем первую значимую строку — она может оказаться шапкой
line_no=0
first_line=""
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  probe="$(trim "$line")"
  case "$probe" in ''|'#'*) continue ;; esac
  first_line="$line"
  HEADER_LINE="$line_no"
  break
done < "$CSV"

[ -n "$first_line" ] || die "в инвентаре нет ни одной строки с данными"

IFS=';' read -ra hdr <<< "$first_line"

# Строка считается шапкой, если ВСЕ её поля — известные названия колонок
# (это допускает любой порядок), либо если первое поле — «ip» (тогда лишняя
# колонка даст понятную ошибку, а не превратится в «устройство»).
all_known=1
for col in "${hdr[@]}"; do
  [ -n "${COLNAME[$(norm_col "$col")]:-}" ] || all_known=0
done

if [ "$all_known" = 1 ] || [ "${COLNAME[$(norm_col "${hdr[0]:-}")]:-}" = "ip" ]; then
  IDX_IP="" IDX_NAME="" IDX_LOC="" IDX_AUTH="" IDX_MOD="" IDX_SITE=""
  i=0
  for col in "${hdr[@]}"; do
    key="${COLNAME[$(norm_col "$col")]:-}"
    case "$key" in
      ip)          IDX_IP=$i ;;
      name)        IDX_NAME=$i ;;
      location)    IDX_LOC=$i ;;
      site)        IDX_SITE=$i ;;
      snmp_auth)   IDX_AUTH=$i ;;
      snmp_module) IDX_MOD=$i ;;
      '')          die "неизвестная колонка «$(trim "$col")» в шапке (строка $HEADER_LINE).
    Допустимые: ip, site, name, location, snmp_auth, snmp_module." ;;
    esac
    i=$((i + 1))
  done
  printf 'шапка найдена (строка %d): колонок %d, есть site: %s\n' \
    "$HEADER_LINE" "${#hdr[@]}" "$([ -n "$IDX_SITE" ] && printf да || printf нет)"
else
  HEADER_LINE=0    # шапки нет — позиционный формат:
                   # IP[:порт];имя;расположение[;snmp_auth[;snmp_module[;site]]]
  IDX_IP=0 IDX_NAME=1 IDX_LOC=2 IDX_AUTH=3 IDX_MOD=4 IDX_SITE=5
fi

tmp_body="$(mktemp)"
trap 'rm -f "$tmp_body"' EXIT

declare -A seen_ip=() seen_name=() seen_site=()
count=0
errors=0
ROW=()

# Значение колонки по её индексу; пустой индекс = колонки нет
getf() {
  local idx="$1"
  [ -n "$idx" ] || return 0
  printf '%s' "${ROW[$idx]:-}"
}

line_no=0    # нумерация для основного прохода — своя (в первом мы уже прошли файл)
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  [ "$line_no" -eq "$HEADER_LINE" ] && continue

  IFS=';' read -ra ROW <<< "$line"

  ip="$(trim "$(getf "$IDX_IP")")"
  name="$(trim "$(getf "$IDX_NAME")")"
  loc="$(trim "$(getf "$IDX_LOC")")"
  auth="$(trim "$(getf "$IDX_AUTH")")"
  mod="$(trim "$(getf "$IDX_MOD")")"
  site="$(trim "$(getf "$IDX_SITE")")"

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
  [ -n "$site" ] && seen_site[$site]=1

  {
    printf -- '- targets:\n'
    printf '    - %s\n' "$ip"
    # site идёт первой: на неё опирается разграничение доступа групп
    if [ -n "$site" ] || [ -n "$name" ] || [ -n "$loc" ] || [ -n "$auth" ] || [ -n "$mod" ]; then
      printf '  labels:\n'
      [ -n "$site" ] && printf "    site: '%s'\n" "$(yaml_quote "$site")"
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
if [ "${#seen_site[@]}" -gt 0 ]; then
  printf 'площадок: %d (%s)\n' "${#seen_site[@]}" "$(printf '%s\n' "${!seen_site[@]}" | sort | paste -sd ',' -)"
else
  printf 'метки site нет ни у одного ИБП: группы подразделений по территориям\n'
  printf 'разграничить не получится — добавьте колонку site (см. docs/access.md)\n'
fi

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
  printf '# Права групп по площадкам (метка site): docs/access.md\n'
  printf '# Prometheus перечитывает файл каждые 30 секунд, перезапуск не нужен.\n'
  printf '# =====================================================================\n'
  printf '\n'
  cat "$tmp_body"
} > "${OUT}.new"

mv "${OUT}.new" "$OUT"
printf 'записано в %s (устройств: %d)\n' "$OUT" "$count"
printf 'проверить: %s/status.sh — и через ~30 с данные появятся в Prometheus\n' "$PROJECT_DIR"
