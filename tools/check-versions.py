#!/usr/bin/env python3
"""Сверка версий компонентов и релизной гигиены.

1) Единственный источник правды по версиям — `run.sh` (`SNMP_VER`, `PROM_VER`,
   `GF_VER`): по ним скачиваются архивы. Скрипт ищет упоминания версий в
   документации, `.env.example` и шаблонах провижининга и падает, если они
   разошлись с `run.sh` — это ровно то расхождение, которое появляется при
   обновлении версий в проекте.

   Строки, где версия указана как исторический факт («проверено на Grafana
   11.5.1»), пропускаются: это не требование к текущей версии.

   `CHANGELOG.md` не сканируется сознательно: там версии по определению
   исторические.

2) С `--tag vX.Y.Z` проверяет, что в `CHANGELOG.md` есть раздел `## [X.Y.Z]`.
   В CI вызывается только на push тега, чтобы релиз не уезжал без записи.

Запуск: `python3 tools/check-versions.py [--tag v1.5.2]`. Зависимостей нет.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RUN_SH = REPO / "run.sh"
CHANGELOG = REPO / "CHANGELOG.md"

# Что и где искать. Первый элемент — имя компонента, второй — регулярка.
PATTERNS = (
    ("snmp_exporter", r"snmp_exporter (\d+\.\d+\.\d+)"),
    ("snmp_exporter", r'SNMP_VER="?(\d+\.\d+\.\d+)"?'),
    ("Prometheus", r"Prometheus (\d+\.\d+\.\d+)"),
    ("Prometheus", r"prometheus-(\d+\.\d+\.\d+)"),
    ("Prometheus", r'PROM_VER="?(\d+\.\d+\.\d+)"?'),
    ("Grafana", r"Grafana (\d+\.\d+\.\d+)"),
    ("Grafana", r"grafana-(\d+\.\d+\.\d+)"),
    ("Grafana", r'GF_VER="?(\d+\.\d+\.\d+)"?'),
)

# Строки с этими пометками не проверяются: это либо исторический факт
# («проверено на …»), либо пример («вписать новую, например PROM_VER="3.2.0"»),
# а не требование к текущей версии.
HISTORICAL = ("проверен", "verified", "испытан", "пример")


def run_sh_versions() -> dict:
    text = RUN_SH.read_text(encoding="utf-8")
    versions = {}
    for key, name in (("SNMP_VER", "snmp_exporter"), ("PROM_VER", "Prometheus"), ("GF_VER", "Grafana")):
        match = re.search(rf'^{key}="?(\d+\.\d+\.\d+)"?', text, re.MULTILINE)
        if not match:
            sys.exit(f"не нашёл {key} в {RUN_SH}")
        versions[name] = match.group(1)
    return versions


def doc_files() -> list:
    files = [REPO / "README.md", REPO / "ROADMAP.md", REPO / ".env.example"]
    files += sorted((REPO / "docs").glob("*.md"))
    files += sorted((REPO / "grafana" / "provisioning").rglob("*.tpl"))
    return [path for path in files if path.is_file()]


def check_versions(versions: dict) -> int:
    problems = []
    matches = 0
    for path in doc_files():
        rel = path.relative_to(REPO)
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            low = line.lower()
            if any(marker in low for marker in HISTORICAL):
                continue
            for name, pattern in PATTERNS:
                for found in re.findall(pattern, line):
                    matches += 1
                    if found != versions[name]:
                        problems.append(
                            f"{rel}:{lineno}: {name} {found}, а в run.sh — {versions[name]}"
                        )
    for msg in problems:
        print(f"  * {msg}", file=sys.stderr)
    if problems:
        return 1
    print(f"Версии в документации совпадают с run.sh ({matches} упоминаний: "
          + ", ".join(f"{k} {v}" for k, v in versions.items()) + ")")
    return 0


def check_tag(tag: str) -> int:
    version = tag[1:] if tag.startswith("v") else tag
    if not CHANGELOG.is_file():
        print(f"нет {CHANGELOG}", file=sys.stderr)
        return 1
    for line in CHANGELOG.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"## [{version}]"):
            print(f"CHANGELOG: раздел для тега {tag} есть — «{line.strip()}»")
            return 0
    print(f"  * в CHANGELOG.md нет раздела «## [{version}]» для тега {tag}",
          file=sys.stderr)
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Сверка версий и релизной гигиены")
    ap.add_argument("--tag", default="", help="тег релиза (v1.5.2) — проверить запись в CHANGELOG")
    args = ap.parse_args()

    if not RUN_SH.is_file():
        print(f"нет {RUN_SH}", file=sys.stderr)
        return 1

    code = check_versions(run_sh_versions())
    if args.tag:
        code = max(code, check_tag(args.tag))
    return code


if __name__ == "__main__":
    sys.exit(main())
