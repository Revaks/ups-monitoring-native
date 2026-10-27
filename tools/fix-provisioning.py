#!/usr/bin/env python3
"""Чистит битые записи dashboard_provisioning у страниц групп.

Grafana хранит в `dashboard_provisioning` числовой `dashboard_id` для каждого
файла провижининга. Если сам дашборд удалили, а запись осталась, при следующем
сканировании Grafana подставляет этот id, не находит дашборд и пишет:

    failed to save dashboard ... error="Dashboard not found"

Файл дашборда при этом на месте и валиден. Скрипт находит такие записи для
указанного файла и с `--fix` удаляет их, предварительно сделав копию
`grafana.db`. Дашборд будет создан заново из файла при следующем старте Grafana.

Перед запуском с `--fix` остановите стек:

    sudo systemctl stop ups-monitoring
    sudo python3 tools/fix-provisioning.py --fix
    sudo systemctl start ups-monitoring

Без `--fix` скрипт только показывает, что нашёл.
"""

from __future__ import annotations

import argparse
import glob
import os
import shutil
import sqlite3
import sys
import time
import urllib.request

DEFAULT_TARGET = "/lowvoltage/ups-lowvoltage.json"
DEFAULT_UID = "ups-lowvoltage"
DEFAULT_ORG = "Служба Слаботочных систем"


def find_dbs() -> list:
    paths = set(glob.glob("/var/lib/prometheus/ups-monitoring/**/grafana.db", recursive=True))
    paths |= set(glob.glob("/opt/ups-monitoring-native/**/grafana.db", recursive=True))
    return sorted(path for path in paths if os.path.isfile(path))


def grafana_answers() -> bool:
    try:
        with urllib.request.urlopen("http://localhost:3000/api/health", timeout=1):
            return True
    except Exception:  # noqa: BLE001
        return False


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Удалить битые записи dashboard_provisioning (Dashboard not found)")
    ap.add_argument("--target", default=DEFAULT_TARGET,
                    help=f"суффикс пути файла в dashboard_provisioning (по умолчанию {DEFAULT_TARGET})")
    ap.add_argument("--uid", default=DEFAULT_UID,
                    help=f"ожидаемый uid дашборда (по умолчанию {DEFAULT_UID})")
    ap.add_argument("--org", default=DEFAULT_ORG,
                    help=f"название организации (по умолчанию {DEFAULT_ORG})")
    ap.add_argument("--db", action="append", default=None,
                    help="путь к grafana.db (можно несколько; по умолчанию ищем сами)")
    ap.add_argument("--fix", action="store_true",
                    help="удалить битые записи (с бэкапом БД)")
    ap.add_argument("--force", action="store_true",
                    help="не проверять, что Grafana остановлена (осторожно)")
    args = ap.parse_args()

    if args.fix and not args.force and grafana_answers():
        sys.exit("Grafana ещё отвечает на localhost:3000 — сначала остановите стек:\n"
                 "    sudo systemctl stop ups-monitoring\n"
                 "    (или повторите с --force, если уверены)")

    dbs = args.db or find_dbs()
    if not dbs:
        sys.exit("не найден grafana.db; укажите путь через --db")

    print("DB:", ", ".join(dbs))
    total_stale = 0

    for db in dbs:
        con = sqlite3.connect(db, timeout=5)
        con.row_factory = sqlite3.Row
        org = con.execute("select id from org where name = ?", (args.org,)).fetchone()
        org_id = org["id"] if org else None
        if org_id is None:
            print(f"! организация «{args.org}» не найдена — проверка org_id отключена")

        rows = con.execute(
            """
            select p.id as prov_id, p.dashboard_id, p.external_id,
                   d.id as dash_id, d.uid, d.org_id, d.folder_id, d.deleted
            from dashboard_provisioning p
            left join dashboard d on d.id = p.dashboard_id
            where p.external_id like ?
            """,
            ("%" + args.target,),
        ).fetchall()

        for row in rows:
            print(" ", dict(row))

        stale = [
            row["prov_id"]
            for row in rows
            if row["dash_id"] is None
            or row["uid"] != args.uid
            or (org_id is not None and row["org_id"] != org_id)
            or row["deleted"] is not None
        ]

        if not stale:
            print(f"{db}: битых записей нет")
            con.close()
            continue

        total_stale += len(stale)
        if not args.fix:
            print(f"{db}: БУДЕТ удалено записей dashboard_provisioning: {stale}")
            con.close()
            continue

        backup = db + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(db, backup)
        con.executemany(
            "delete from dashboard_provisioning where id = ?",
            [(prov_id,) for prov_id in stale],
        )
        con.commit()
        con.close()
        print(f"{db}: удалено записей {stale}, бэкап {backup}")

    if total_stale == 0:
        print("Итог: битых записей не найдено. Если ошибка осталась, пришлите вывод выше.")
    elif args.fix:
        print("Итог: исправлено. Запустите стек: sudo systemctl start ups-monitoring")
    else:
        print("Итог: это только проверка. Повторите с --fix, чтобы удалить.")


if __name__ == "__main__":
    main()
