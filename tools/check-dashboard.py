#!/usr/bin/env python3
"""Семантические проверки дашбордов Grafana — то, чего не видит `jq -e`.

Проверяет по каждому файлу `grafana/dashboards/*.json`:

  1. уникальность `panel id` (дубли появляются при копировании панелей и ломают
     ссылки «?panelId=…» и вкладки в URL);
  2. раскладку `gridPos`: панель влезает в сетку (x + w <= 24) и соседние панели
     одного ряда не перекрываются (после удаления панели легко оставить дырку
     или наложение — в браузере это видно только глазами);
  3. все панели, кроме `row`/`alertlist`, ходят в разрешённые источники данных
     (по умолчанию `prometheus`) — ловит «случайную» панель с `-- Grafana --`
     и Random Walk;
  4. внутренние ссылки `/d/<uid>/…` указывают на существующий дашборд;
  5. монитор — первый экран обзора в отдельном дашборде: 8 счётчиков,
     «Требует внимания» с фиксированным размером текста, «Активные алерты»,
     «Последний опрос ИБП», «Парк» и ссылка обратно на обзор.

Дополнительно, если рядом лежит `grafana-groups.py`, для каждого дашборда
собираются копии группы (`make_group_dashboard`) в двух вариантах доступа —
ручной regex по `location` и список площадок (`site`) — и проверяются отдельно:
копии живут в своей организации, поэтому **все** ссылки в них должны вести на
копии этой организации, а не на базовые дашборды из Main Org, а фильтр доступа
обязан попасть в каждое выражение с `job="snmp"` (пропущенное выражение =
панель, показывающая чужую территорию).

Запуск: `python3 tools/check-dashboard.py` (из любого каталога — путь к репозиторию
берётся от расположения скрипта). Ненулевой код возврата — есть проблемы.
Зависимостей нет, годится и для CI, и для локальной проверки перед коммитом.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GRID_MAX_WIDTH = 24                      # ширина сетки Grafana в клетках
DEFAULT_DATASOURCES = ("prometheus",)    # uid источников, допустимых в дашбордах
# Панели без запросов к источнику данных: список алертов читает правила самой
# Grafana. У них нет datasource и targets — проверка источника к ним не относится.
NO_QUERY_PANELS = ("row", "alertlist")
LINK_RE = re.compile(r"/d/([A-Za-z0-9\-_]+)")


def load(path: Path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def collect_ids(panels, ids: dict, errors: list, name: str, place: str = "") -> None:
    """Собирает panel id по всему дашборду: они общие для всех уровней."""
    for idx, panel in enumerate(panels):
        here = f"{place}[{idx}]" if place else f"[{idx}]"
        pid = panel.get("id")
        if pid is not None:
            if pid in ids:
                errors.append(f"{name}: panel id {pid} повторяется ({ids[pid]} и {here})")
            else:
                ids[pid] = here
        collect_ids(panel.get("panels") or [], ids, errors, name, here)


def check_container(name: str, panels: list, errors: list, place: str = "") -> int:
    """Проверяет один контейнер панелей: источник данных, границы, перекрытия.

    Перекрытия ищем только среди соседей (вложенные панели строк имеют свою
    систему координат, поэтому с панелями других строк их сравнивать нельзя).
    """
    count = 0
    for idx, panel in enumerate(panels):
        count += 1
        title = panel.get("title") or panel.get("type") or "?"
        here = f"{place}[{idx}]" if place else f"[{idx}]"

        if panel.get("type") not in NO_QUERY_PANELS or panel.get("targets"):
            ds = panel.get("datasource")
            uid = ds.get("uid") if isinstance(ds, dict) else ds
            if uid not in DEFAULT_DATASOURCES:
                errors.append(
                    f"{name}: панель «{title}» ({here}) с источником {uid!r} — "
                    f"ожидается один из {list(DEFAULT_DATASOURCES)}"
                )

        grid = panel.get("gridPos") or {}
        x, w, y = grid.get("x", 0), grid.get("w", 0), grid.get("y")
        if grid:
            if x < 0 or w <= 0 or x + w > GRID_MAX_WIDTH:
                errors.append(
                    f"{name}: панель «{title}» ({here}) не влезает в сетку: "
                    f"x={x}, w={w} (предел {GRID_MAX_WIDTH})"
                )
            else:
                for other in panels[idx + 1:]:
                    ogrid = other.get("gridPos") or {}
                    if ogrid.get("y") != y:
                        continue
                    ox, ow = ogrid.get("x", 0), ogrid.get("w", 0)
                    if x < ox + ow and ox < x + w:
                        errors.append(
                            f"{name}: панели «{title}» и «{other.get('title')}» "
                            f"перекрываются в ряду y={y}: x={x} w={w} против x={ox} w={ow}"
                        )

        nested = panel.get("panels")
        if nested:
            count += check_container(name, nested, errors, here)
    return count


def iter_strings(obj):
    """Все строки JSON — по ним ищем ссылки внутри дашборда."""
    if isinstance(obj, dict):
        for val in obj.values():
            yield from iter_strings(val)
    elif isinstance(obj, list):
        for val in obj:
            yield from iter_strings(val)
    elif isinstance(obj, str):
        yield obj


def count_marker(dash: dict, needle: str) -> int:
    return sum(text.count(needle) for text in iter_strings(dash))


def check_links(name: str, dash: dict, allowed: set, errors: list) -> int:
    """Каждая ссылка /d/<uid>/… должна указывать на дашборд из этого же места."""
    seen = 0
    for text in iter_strings(dash):
        for uid in LINK_RE.findall(text):
            seen += 1
            if uid not in allowed:
                errors.append(
                    f"{name}: ссылка ведёт на /d/{uid}/, а такого дашборда рядом "
                    f"нет (есть: {', '.join(sorted(allowed)) or '—'})"
                )
    return seen


def load_groups_module():
    path = REPO / "tools" / "grafana-groups.py"
    if not path.is_file():
        print(f"проверка копий групп пропущена: нет {path}", file=sys.stderr)
        return None
    spec = importlib.util.spec_from_file_location("grafana_groups", path)
    if spec is None or spec.loader is None:
        print(f"не удалось загрузить {path}", file=sys.stderr)
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Варианты доступа группы: ручной regex по location (как было) и список
# площадок (site). Второй проверяет, что фильтр доезжает до ВСЕХ выражений —
# именно на нём держится разграничение прав между подразделениями.
GROUP_VARIANTS = (
    ("regex", "selfcheck-loc", ".*", None),
    # Название площадки со спецсимволами RE2: проверяем, что экранирование
    # даёт валидный PromQL, а не только простые названия.
    ("sites", "selfcheck-site", None, ["Площадка №1", "ЦОД-1 (основной)"]),
)


def check_one_copy(module, name: str, dash: dict, slug: str, regex, sites,
                   uid_map: dict, errors: list) -> tuple:
    """Собирает одну копию группы и проверяет её как отдельный дашборд."""
    base_uid = dash.get("uid")
    expected_uid = module.group_dashboard_uid(base_uid, slug)
    result = module.make_group_dashboard(
        dash, slug, f"{dash.get('title')} ({slug})", regex, sites=sites,
        uid=expected_uid, uid_map=uid_map)
    # Старые версии скрипта возвращали (дашборд, число замен) без ссылок.
    copy, replaced = result[0], result[1]
    links = result[2] if len(result) > 2 else None
    copy_name = f"{name} (копия {expected_uid})"

    if copy.get("uid") != expected_uid:
        errors.append(f"{copy_name}: uid копии {copy.get('uid')!r} вместо {expected_uid!r}")

    # Провижининг сам назначает id и папку. Если в JSON остался числовой id
    # (например, из экспорта дашборда), Grafana пытается обновить
    # несуществующий дашборд и падает с «Dashboard not found» — обзор
    # группы так и не появляется, хотя файл на месте.
    for key in ("id", "folderId", "folderUid"):
        if key in copy:
            errors.append(
                f"{copy_name}: в копии остался ключ {key!r} — провижининг "
                f"Grafana может ответить «Dashboard not found»"
            )

    # В организации группы нет ни одного базового дашборда: после копирования
    # не должно остаться ссылок ни на обзор, ни на монитор из Main Org.
    # Сравниваем uid целиком: `/d/ups-monitor/...` — префикс для
    # `/d/ups-monitor-selfcheck/...`, простой count() дал бы ложную ошибку.
    for old_uid in uid_map:
        pattern = re.compile(rf"/d/{re.escape(old_uid)}(?:[/?]|$)")
        left = sum(len(pattern.findall(text)) for text in iter_strings(copy))
        if left:
            errors.append(
                f"{copy_name}: осталась ссылка на базовый дашборд /d/{old_uid}/ — "
                f"в организации группы существуют только копии"
            )

    expected = count_marker(dash, 'job="snmp"')
    if expected and not replaced:
        errors.append(
            f"{copy_name}: фильтр доступа не подставился ни в одно из "
            f"{expected} выражений с job=\"snmp\""
        )

    # Фильтр по площадкам обязан попасть в каждое выражение: пропущенное
    # выражение = панель, которая покажет чужую территорию.
    if sites:
        matcher = module.sites_matcher(sites)
        got = count_marker(copy, f'site=~"{matcher}"')
        if got < expected:
            errors.append(
                f"{copy_name}: фильтр площадок попал только в {got} из {expected} "
                f"выражений — часть панелей покажет чужие территории"
            )

    check_container(copy_name, copy.get("panels") or [], errors)
    # Копии одной организации ссылаются друг на друга (обзор <-> монитор),
    # поэтому разрешены все uid копий, а не только uid этой панели.
    check_links(copy_name, copy, set(uid_map.values()), errors)
    return copy_name, links


def check_group_copies(module, dashes: dict, errors: list) -> int:
    """Собирает копии для фиктивной группы и проверяет их как отдельные дашборды."""
    checked = 0
    for name, dash in dashes.items():
        for label, slug, regex, sites in GROUP_VARIANTS:
            # Карта uid строится по всем дашбордам сразу: копия монитора
            # должна ссылаться на копию обзора этой же группы.
            uid_map = {
                d["uid"]: module.group_dashboard_uid(d["uid"], slug)
                for d in dashes.values() if d.get("uid")
            }
            copy_name, links = check_one_copy(
                module, name, dash, slug, regex, sites, uid_map, errors)
            checked += 1
            if links is not None:
                print(f"  {copy_name} [{label}]: ссылок переадресовано на копии — {links}")

    # Группа без монитора: обзор не должен ссылаться на монитор из Main Org.
    monitor = dashes.get("ups-monitor.json")
    overview = dashes.get("ups-overview.json")
    if monitor and overview:
        slug = "selfcheck-nomon"
        uid_map = {
            overview["uid"]: module.group_dashboard_uid(overview["uid"], slug)}
        copy = module.make_group_dashboard(
            overview, slug, "Обзор без монитора", None,
            sites=["Площадка №1"], uid_map=uid_map)[0]
        module.drop_dashboard_links(copy, monitor["uid"])
        left = sum(len(re.findall(rf"/d/{re.escape(monitor['uid'])}[/?]",
                                  text)) for text in iter_strings(copy))
        if left:
            errors.append(
                "ups-overview.json (копия без монитора): осталась ссылка на "
                "монитор из Main Org — группе она недоступна")
        checked += 1
    return checked


# Отчёт за период приходит на смену таймлайнам состояния. Таймлайн информативен
# только когда состояние меняется: на здоровом парке он рисует сплошную зелёную
# заливку, то есть не сообщает ничего. Отчёт даёт числа за выбранный период.
REPORT_TITLE = "Отчёт за период"

# Колонки отчёта: человекочитаемое имя -> подстрока в выражении панели.
REPORT_COLUMNS = (
    ("доступность за период", 'avg_over_time(up{job="snmp"'),
    ("доступность в процентах", "* 100"),
    ("минуты на батарее", 'avg_over_time((upsOutputSource{job="snmp"'),
    # Переходов должно быть целым: changes() считает смены состояния, а эпизод
    # на батарее даёт две смены (ушёл и вернулся). Без округления вверх в
    # отчёте появляется «2,5 перехода» — число, которого не бывает.
    ("переходы на батарею", "ceil(max by (instance) (changes((upsOutputSource"),
    ("минимальный заряд", "min_over_time(upsEstimatedChargeRemaining"),
    ("максимальная нагрузка", "max_over_time(upsOutputPercentLoad"),
)

# Панели-таймлайны, которые отчёт заменяет.
REPLACED_PANELS = ("Доступность ИБП, 24 часа", "Источник питания, 24 часа")


def find_panel(panels, title):
    """Панель по заголовку на любом уровне вложенности (внутри строк тоже)."""
    for panel in panels:
        if panel.get("title") == title:
            return panel
        found = find_panel(panel.get("panels") or [], title)
        if found is not None:
            return found
    return None


def check_report(name: str, dash: dict, errors: list) -> None:
    """Дашборд должен давать отчёт за период, а не только текущее состояние."""
    panels = dash.get("panels") or []

    for old_title in REPLACED_PANELS:
        if find_panel(panels, old_title) is not None:
            errors.append(
                f"{name}: панель «{old_title}» осталась — на здоровом парке она "
                f"показывает сплошную заливку вместо отчётности "
                f"(замена — «{REPORT_TITLE}»)"
            )

    panel = find_panel(panels, REPORT_TITLE)
    if panel is None:
        errors.append(f"{name}: нет панели «{REPORT_TITLE}»")
        return

    if panel.get("type") != "table":
        errors.append(
            f"{name}: «{REPORT_TITLE}» имеет тип {panel.get('type')!r}, "
            f"ожидается table — отчёт читают по столбцам"
        )

    joined = " ".join(t.get("expr") or "" for t in panel.get("targets") or [])
    for label, marker in REPORT_COLUMNS:
        if marker not in joined:
            errors.append(f"{name}: в «{REPORT_TITLE}» нет колонки «{label}»")

    # Период обязан браться из выбора времени Grafana, иначе отчёт нельзя
    # посчитать «за сутки», «за неделю» или «за месяц».
    if "$__range" not in joined:
        errors.append(
            f"{name}: «{REPORT_TITLE}» не использует $__range — отчёт не будет "
            f"пересчитываться при смене периода"
        )


def check_monitor(name: str, dash: dict, errors: list) -> None:
    """Монитор — первый экран обзора в отдельном дашборде, без «расплывания»."""
    if dash.get("uid") != "ups-monitor":
        return

    panels = dash.get("panels") or []
    stats = [p for p in panels if p.get("type") == "stat"]
    if len(stats) != 8:
        errors.append(
            f"{name}: счётчиков {len(stats)}, ожидается 8 (5 показателей питания "
            f"и связи, «Требует внимания», «Последний опрос», «Парк»)"
        )

    # «Требует внимания» — многорядная stat-плитка. Без фиксированного
    # valueSize Grafana растягивает единственную проблему на всю панель.
    problems = find_panel(panels, "Требует внимания")
    if problems is None:
        errors.append(f"{name}: нет панели «Требует внимания»")
    else:
        options = problems.get("options") or {}
        size = (options.get("text") or {}).get("valueSize")
        if problems.get("type") != "stat" or not isinstance(size, int) or size <= 0:
            errors.append(
                f"{name}: у «Требует внимания» нет фиксированного размера текста "
                f"(options.text.valueSize) — одна проблема растянется на всю панель"
            )

    alerts = find_panel(panels, "Активные алерты")
    if alerts is None or alerts.get("type") != "alertlist":
        errors.append(f"{name}: нет панели «Активные алерты» (type=alertlist)")

    last_poll = find_panel(panels, "Последний опрос ИБП")
    if last_poll is None:
        errors.append(f"{name}: нет панели «Последний опрос ИБП»")

    fleet = find_panel(panels, "Парк")
    if fleet is None:
        errors.append(f"{name}: нет панели «Парк»")

    if not any("/d/ups-overview/" in text for text in iter_strings(dash)):
        errors.append(f"{name}: нет ссылки обратно на «ИБП — обзор»")


def main() -> int:
    ap = argparse.ArgumentParser(description="Семантические проверки дашбордов Grafana")
    ap.add_argument("--dir", default=str(REPO / "grafana" / "dashboards"),
                    help="каталог с дашбордами (по умолчанию grafana/dashboards)")
    ap.add_argument("--no-groups", action="store_true",
                    help="не проверять копии дашбордов для групп")
    args = ap.parse_args()

    dash_dir = Path(args.dir)
    files = sorted(dash_dir.glob("*.json"))
    if not files:
        print(f"нет дашбордов в {dash_dir}", file=sys.stderr)
        return 1

    errors: list = []
    dashes: dict = {}
    uids: dict = {}
    panels_total = 0
    links_total = 0

    for path in files:
        name = path.name
        try:
            dash = load(path)
        except json.JSONDecodeError as exc:
            errors.append(f"{name}: некорректный JSON ({exc})")
            continue
        dashes[name] = dash
        uid = dash.get("uid")
        if uid:
            uids[uid] = name
        else:
            errors.append(f"{name}: нет uid — на такой дашборд нельзя дать ссылку")
        ids: dict = {}
        collect_ids(dash.get("panels") or [], ids, errors, name)
        panels_total += check_container(name, dash.get("panels") or [], errors)
        # «Отчёт за период» — требование обзора. У монитора другая задача:
        # крупные показатели и список проблем, отчёт там не нужен.
        if path.name == "ups-overview.json":
            check_report(name, dash, errors)
        check_monitor(name, dash, errors)

    for name, dash in dashes.items():
        links_total += check_links(name, dash, set(uids), errors)

    groups_checked = 0
    if not args.no_groups:
        module = load_groups_module()
        if module is not None:
            groups_checked = check_group_copies(module, dashes, errors)

    if errors:
        print(f"Проверка дашбордов: проблем — {len(errors)}\n", file=sys.stderr)
        for msg in errors:
            print(f"  * {msg}", file=sys.stderr)
        return 1

    print(f"Дашборды OK: файлов {len(dashes)}, панелей {panels_total}, "
          f"внутренних ссылок {links_total}")
    if groups_checked:
        print(f"Копии групп OK: собрано и проверено {groups_checked} "
              f"(варианты regex по location и список площадок), "
              f"ссылки ведут на сами копии, фильтр доступа подставляется во все выражения")
    return 0


if __name__ == "__main__":
    sys.exit(main())
