#!/usr/bin/env python3
# =====================================================================
#  grafana-groups.py — организации Grafana «только для чтения» с отдельной
#  страницей мониторинга для каждой группы (инженеры/операторы/слаботочники).
#
#  Что делает (идемпотентно, можно запускать повторно):
#    1. создаёт организации Grafana по списку из groups.json;
#    2. раскладывает файлы провижининга: свой Prometheus-датасорс в каждой
#       организации и свой провайдер дашбордов (папка = страница группы);
#    3. генерирует дашборд группы из штатного ups-overview.json, подставляя
#       в запросы фильтр по метке location (у операторов/слаботочников —
#       только их ИБП);
#    4. создаёт локальные аккаунты с ролью Viewer в нужной организации;
#    5. ставит домашний дашборд организации (лендинг после входа).
#
#  Требует python3 (только этот скрипт, сам стек его не использует).
#
#  Запуск (на сервере, от root — нужен доступ к .env с паролем Grafana):
#    cp tools/grafana-groups.example.json /root/groups.json   # и поправить под себя
#    sudo python3 tools/grafana-groups.py --config /root/groups.json --dry-run
#    sudo python3 tools/grafana-groups.py --config /root/groups.json --restart
#
#  Подробности, настройка групп и проверка: docs/access.md
# =====================================================================
import argparse
import base64
import json
import os
import secrets
import string
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def log(msg: str) -> None:
    print("   " + msg, flush=True)


def step(msg: str) -> None:
    print("\n==> " + msg, flush=True)


def die(msg: str) -> "NoReturn":  # noqa: F821
    print("\nerror: " + msg + "\n", file=sys.stderr)
    sys.exit(1)


class Api:
    def __init__(self, url: str, user: str, password: str, dry: bool) -> None:
        self.url = url.rstrip("/")
        self.auth = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.dry = dry

    def call(self, method: str, path: str, body=None, tolerate: bool = False):
        """tolerate=True — не падать, если Grafana ещё не слушает порт
        (нужно в ожидании после перезапуска стека)."""
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method)
        req.add_header("Authorization", "Basic " + self.auth)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode(errors="replace")
            if exc.code == 404:
                return None
            if tolerate:
                return None
            raise SystemExit(f"Grafana API {method} {path} -> HTTP {exc.code}: {raw[:300]}")
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as exc:
            # порт ещё не слушается (Grafana стартует) или сеть недоступна
            if tolerate:
                return None
            raise SystemExit(
                f"Grafana недоступна по адресу {self.url} ({exc}).\n"
                f"    Проверьте: systemctl status {os.environ.get('UPS_SERVICE', 'ups-monitoring')} "
                f"и что адрес указан верно (--url).")


def read_env(path: str) -> dict:
    """Читает .env стека (KEY=VALUE, без секретов в выводе)."""
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                out[key.strip()] = val.strip().strip("'\"")
    except FileNotFoundError:
        pass
    return out


def gen_password(n: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits + "-_%@+="
    return "".join(secrets.choice(alphabet) for _ in range(n))


# --------------------------------------------------------------- dashboards
def inject_location_filter(obj, regex: str, path: str = "$") -> int:
    """Подставляет location=~"regex" во все matcher'ы {job="snmp"}.

    Работает рекурсивно по всему JSON дашборда: выражения панелей,
    запросы переменных. Возвращает число заменённых строк.
    """
    changed = 0
    if isinstance(obj, dict):
        for key, val in obj.items():
            if isinstance(val, str) and 'job="snmp"' in val and "location=~" not in val:
                obj[key] = val.replace('job="snmp"', f'job="snmp", location=~"{regex}"')
                changed += 1
            else:
                changed += inject_location_filter(val, regex, f"{path}.{key}")
    elif isinstance(obj, list):
        for i, val in enumerate(obj):
            changed += inject_location_filter(val, regex, f"{path}[{i}]")
    return changed


def make_group_dashboard(base: dict, slug: str, title: str, regex) -> tuple:
    dash = json.loads(json.dumps(base))  # глубокая копия
    dash["uid"] = f"ups-{slug}"
    dash["title"] = title
    dash["id"] = None
    dash["version"] = 0
    if "meta" in dash:
        del dash["meta"]
    n = 0
    if regex:
        n = inject_location_filter(dash, regex)
        dash["tags"] = sorted(set(dash.get("tags", []) + ["group", slug]))
    return dash, n


# ------------------------------------------------------------------ YAML
def yaml_datasources(groups, ds_url: str) -> str:
    lines = [
        "# Создано grafana-groups.py — датасорс Prometheus для организаций групп.",
        "# Файл НЕ входит в репозиторий проекта: обновление стека его не затирает.",
        "apiVersion: 1",
        "",
        "datasources:",
    ]
    for g in groups:
        lines += [
            f"  - name: Prometheus",
            f"    uid: prometheus",
            f"    orgId: {g['orgId']}",
            f"    type: prometheus",
            f"    access: proxy",
            f"    url: {ds_url}",
            f"    isDefault: true",
            f"    editable: false",
            f"    jsonData:",
            f"      timeInterval: 30s",
        ]
    return "\n".join(lines) + "\n"


def yaml_dashboards(groups, install_dir: str) -> str:
    lines = [
        "# Создано grafana-groups.py — провайдеры дашбордов по организациям групп.",
        "apiVersion: 1",
        "",
        "providers:",
    ]
    for g in groups:
        lines += [
            f"  - name: 'group-{g['slug']}'",
            f"    orgId: {g['orgId']}",
            f"    folder: '{g['org']}'",
            f"    type: file",
            f"    disableDeletion: true",
            f"    allowUiUpdates: false",
            f"    updateIntervalSeconds: 30",
            f"    options:",
            f"      path: {install_dir}/grafana/dashboards-groups/{g['slug']}",
            f"      foldersFromFilesStructure: false",
        ]
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description="Группы Grafana: организации, страницы, аккаунты (только чтение)")
    ap.add_argument("--config", required=True, help="путь к groups.json")
    ap.add_argument("--dir", default=os.environ.get("UPS_DIR", "/opt/ups-monitoring-native"),
                    help="каталог установки стека (по умолчанию /opt/ups-monitoring-native)")
    ap.add_argument("--url", default=None, help="адрес Grafana (по умолчанию из groups.json или http://localhost:3000)")
    ap.add_argument("--dry-run", action="store_true", help="ничего не менять, только показать план")
    ap.add_argument("--restart", action="store_true",
                    help="перезапустить стек самому и затем выставить домашние страницы "
                         "(иначе запустите скрипт повторно после перезапуска)")
    ap.add_argument("--service", default="ups-monitoring", help="имя systemd-юнита стека")
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        cfg = json.load(fh)

    install_dir = args.dir.rstrip("/")
    env = read_env(os.path.join(install_dir, ".env"))

    grafana_url = args.url or cfg.get("grafana_url") or "http://localhost:3000"
    ds_url = cfg.get("datasource_url") or f"http://localhost:{env.get('PROMETHEUS_PORT', '9090')}"
    admin_user = cfg.get("admin_user") or env.get("GRAFANA_ADMIN_USER", "admin")
    admin_pass = cfg.get("admin_password") or env.get("GRAFANA_ADMIN_PASSWORD", "")

    if not admin_pass:
        die("не нашёл пароль администратора Grafana: укажите admin_password в groups.json "
            "или запускайте от root, чтобы прочитать .env")

    base_path = cfg["base_dashboard"]
    if not base_path.startswith("/"):
        base_path = os.path.join(install_dir, base_path)
    with open(base_path, encoding="utf-8") as fh:
        base_dash = json.load(fh)

    api = Api(grafana_url, admin_user, admin_pass, args.dry_run)
    me = api.call("GET", "/api/user")
    if not me:
        die(f"Grafana не отвечает или неверные данные администратора: {grafana_url}")
    if not me.get("isGrafanaAdmin"):
        die(f"пользователь {admin_user} не серверный администратор — организации создавать нельзя")
    log(f"Grafana: {grafana_url} ({me.get('login')}, серверный админ)")

    if args.dry_run:
        log("режим --dry-run: изменения не вносятся")

    # --- 1. организации ---
    step("Организации")
    existing = {o["name"]: o["id"] for o in (api.call("GET", "/api/orgs") or [])}
    for g in cfg["groups"]:
        name = g["org"]
        if name in existing:
            g["orgId"] = existing[name]
            log(f"{name}: уже есть (orgId={g['orgId']})")
            continue
        if args.dry_run:
            g["orgId"] = 0
            log(f"{name}: БУДЕТ создана")
            continue
        res = api.call("POST", "/api/orgs", {"name": name})
        g["orgId"] = res["orgId"]
        log(f"{name}: создана (orgId={g['orgId']})")

    def filter_matches(regex: str):
        """Сколько ИБП попадает под фильтр location. None — Prometheus недоступен."""
        query = f'count(up{{job="snmp", location=~"{regex}"}}) or vector(0)'
        url = ds_url.rstrip("/") + "/api/v1/query?query=" + urllib.parse.quote(query)
        try:
            with urllib.request.urlopen(url, timeout=10) as resp:
                data = json.loads(resp.read())
            res = data["data"]["result"]
            return int(float(res[0]["value"][1])) if res else 0
        except Exception:  # noqa: BLE001
            return None

    # --- 2. дашборды в файлы ---
    step("Дашборды групп")
    for g in cfg["groups"]:
        dash, replaced = make_group_dashboard(base_dash, g["slug"], g["title"], g.get("location_filter"))
        target_dir = os.path.join(install_dir, "grafana", "dashboards-groups", g["slug"])
        target = os.path.join(target_dir, f"{dash['uid']}.json")
        matched = filter_matches(g["location_filter"]) if g.get("location_filter") else None
        note = f"фильтр: {g['location_filter']!r}, замен: {replaced}"
        if matched is not None:
            note += f", под фильтр попадает ИБП: {matched}"
        if args.dry_run:
            log(f"{g['org']}: {target} ({note})")
        else:
            os.makedirs(target_dir, exist_ok=True)
            with open(target, "w", encoding="utf-8") as fh:
                json.dump(dash, fh, ensure_ascii=False, indent=2)
                fh.write("\n")
            log(f"{g['org']}: {target} ({note})")
        if matched == 0:
            log(f"    ! ВНИМАНИЕ: под фильтр {g['location_filter']!r} не попал ни один ИБП — "
                f"проверьте метки location в targets.yml (regex в PromQL анкорится целиком, "
                f"для префикса нужен суффикс .*)")

    # --- 3. провижининг ---
    step("Файлы провижининга")
    prov = os.path.join(install_dir, "grafana", "provisioning")
    files = {
        os.path.join(prov, "datasources", "groups.yml"): yaml_datasources(cfg["groups"], ds_url),
        os.path.join(prov, "dashboards", "groups.yml"): yaml_dashboards(cfg["groups"], install_dir),
    }
    for path, text in files.items():
        if args.dry_run:
            log(f"БУДЕТ записан {path}")
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        log(f"записан {path}")

    # --- 4. пользователи ---
    step("Аккаунты (роль Viewer в своей организации)")
    created = []
    for g in cfg["groups"]:
        for u in g.get("users", []):
            login = u["login"]
            found = api.call("GET", f"/api/users/lookup?loginOrEmail={login}")
            if found and found.get("id"):
                log(f"{login}: уже есть (id={found['id']}, организация {g['org']})")
                continue
            if args.dry_run:
                log(f"{login}: БУДЕТ создан в «{g['org']}»")
                continue
            password = u.get("password") or gen_password()
            res = api.call("POST", "/api/admin/users", {
                "name": u.get("name", login),
                "email": u.get("email", f"{login}@example.local"),
                "login": login,
                "password": password,
                "OrgId": g["orgId"],
            })
            created.append((login, password, g["org"]))
            # пароль печатаем сразу: если скрипт упадёт на следующих шагах,
            # он не потеряется (итоговая сводка идёт в самом конце)
            log(f"{login}: создан (id={res.get('id')}) в «{g['org']}», роль Viewer, "
                f"пароль: {password}")

    # --- 5. перезапуск стека (если просили) ---
    # Провайдер дашбордов читается Grafana при старте, поэтому новые файлы
    # провижининга подхватятся только после перезапуска. Домашнюю страницу
    # имеет смысл ставить уже после — на несуществующий дашборд Grafana её
    # молча не сохраняет.
    ready = True
    if args.restart and not args.dry_run:
        step(f"Перезапуск стека ({args.service})")
        try:
            subprocess.run(["systemctl", "restart", args.service], check=True)
            log("systemctl restart выполнен")
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            log(f"не удалось перезапустить через systemctl ({exc}); перезапустите вручную")
        # Grafana поднимается не мгновенно: ждём, пока порт начнёт отвечать.
        # tolerate=True — «порт ещё закрыт» это нормальная ситуация, а не ошибка.
        ready, deadline = False, time.time() + 180
        while time.time() < deadline:
            if api.call("GET", "/api/health", tolerate=True):
                ready = True
                break
            time.sleep(2)
        log("Grafana снова отвечает" if ready
            else f"Grafana не ответила за 180 с — проверьте: systemctl status {args.service}")

    # --- 6. домашний дашборд организации (лендинг группы) ---
    step("Домашняя страница организаций")
    if not ready:
        log("Grafana недоступна — домашние страницы не выставляю")
        log("  когда стек поднимется, запустите скрипт ещё раз (без --restart):")
        log(f"    sudo python3 {os.path.basename(__file__)} --config {args.config}")
    else:
        for g in cfg["groups"]:
            uid = f"ups-{g['slug']}"
            if args.dry_run:
                log(f"{g['org']}: БУДЕТ home = {uid}")
                continue
            api.call("POST", f"/api/user/using/{g['orgId']}")      # переключить контекст
            if not api.call("GET", f"/api/dashboards/uid/{uid}", tolerate=True):
                log(f"{g['org']}: дашборд {uid} ещё не провижинился — "
                    f"перезапустите стек и запустите скрипт снова")
                continue
            api.call("PUT", "/api/org/preferences", {"homeDashboardUID": uid})
            log(f"{g['org']}: home = {uid}")
        api.call("POST", "/api/user/using/1")                      # вернуться в Main Org

    # --- итог ---
    print()
    if created:
        print("Пароли созданных аккаунтов (сохраните, показаны один раз):")
        for login, password, org in created:
            print(f"  {login:20s} {password:20s}  ({org})")
        print()
    if not args.restart:
        print("Дальше: sudo systemctl restart ups-monitoring   # применить провижининг,")
        print("затем запустите скрипт ещё раз — он выставит домашние страницы.")
        print("(либо сразу запускать с --restart)")
    print("Проверка: войти под аккаунтом группы — откроется её страница,")
    print("в меню видна только своя папка, кнопок правки/сохранения нет.")


if __name__ == "__main__":
    main()
