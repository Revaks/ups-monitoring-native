#!/usr/bin/env python3
"""Семантические проверки дашбордов Grafana — то, чего не видит `jq -e`.

Проверяет по каждому файлу `grafana/dashboards/*.json`:

  1. уникальность `panel id` (дубли появляются при копировании панелей и ломают
     ссылки «?panelId=…» и вкладки в URL);
  2. раскладку `gridPos`: панель влезает в сетку (x + w <= 24) и соседние панели
     одного ряда не перекрываются (после удаления панели легко оставить дырку
     или наложение — в браузере это видно только глазами);
  3. все панели, кроме `row`, ходят в разрешённые источники данных (по умолчанию
     `prometheus`) — ловит «случайную» панель с `-- Grafana --` и Random Walk;
  4. внутренние ссылки `/d/<uid>/…` указывают на существующий дашборд.

Дополнительно, если рядом лежит `grafana-groups.py`, для каждого дашборда
собирается копия группы (`make_group_dashboard`) и проверяется отдельно: копия
живёт в своей организации, поэтому **все** ссылки в ней должны вести на неё
саму, а не на базовый дашборд из Main Org.

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

        if panel.get("type") != "row":
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


def check_group_copies(module, dashes: dict, errors: list) -> int:
    """Собирает копии для фиктивной группы и проверяет их как отдельные дашборды."""
    checked = 0
    for name, dash in dashes.items():
        slug = "selfcheck"
        result = module.make_group_dashboard(
            dash, slug, f"{dash.get('title')} (selfcheck)", ".*")
        # Старые версии скрипта возвращали (дашборд, число замен) без ссылок.
        copy, replaced = result[0], result[1]
        links = result[2] if len(result) > 2 else None
        copy_name = f"{name} (копия группы ups-{slug})"
        checked += 1

        if copy.get("uid") != f"ups-{slug}":
            errors.append(f"{copy_name}: uid копии {copy.get('uid')!r} вместо ups-{slug}")

        base_uid = dash.get("uid")
        if base_uid:
            left = sum(text.count(f"/d/{base_uid}") for text in iter_strings(copy))
            if left:
                errors.append(
                    f"{copy_name}: осталась ссылка на базовый дашборд /d/{base_uid}/ — "
                    f"в организации группы существует только сама копия"
                )
            elif left == 0 and links is not None:
                print(f"  {copy_name}: ссылок переадресовано на свою копию — {links}")

        expected = count_marker(dash, 'job="snmp"')
        if expected and not replaced:
            errors.append(
                f"{copy_name}: фильтр location не подставился ни в одно из "
                f"{expected} выражений с job=\"snmp\""
            )

        check_container(copy_name, copy.get("panels") or [], errors)
        check_links(copy_name, copy, {copy.get("uid")}, errors)
    return checked


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
        print(f"Копии групп OK: собрано и проверено {groups_checked}, "
              f"ссылки ведут на сами копии, фильтр location подставляется")
    return 0


if __name__ == "__main__":
    sys.exit(main())
