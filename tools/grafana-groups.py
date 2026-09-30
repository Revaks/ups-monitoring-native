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
#       в запросы фильтр доступа: список площадок (метка site) и/или ручной
#       regex по метке location — у электриков видны только ИБП их территорий;
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
# Символы, значимые для регулярных выражений RE2 (PromQL): их экранируем в
# значениях меток, иначе «Площадка №1 (основная)» превратится в группу в regex.
REGEX_SPECIAL = set(r"\.+*?()|[]{}^$")


def escape_regex(value: str) -> str:
    """Экранирует значение метки для подстановки в regex PromQL.

    Каждый спецсимвол получает ДВА обратных слэша. Выражение попадает в
    строковый литерал PromQL, который сам разбирает escape-последовательности:
    одиночный `\\(` он отвергает с ошибкой «unknown escape sequence», и уже
    после разбора строки до RE2 доходит один слэш — то есть «литеральная
    скобка». Проверено `promtool check rules`: «Площадка №1 (основная)» без
    удвоения ломала разбор всего выражения.
    """
    return "".join("\\\\" + ch if ch in REGEX_SPECIAL else ch for ch in value)


def sites_matcher(sites) -> str:
    """Regex «ровно одна из площадок списка».

    `=~` в PromQL анкорится целиком, но скобки оставляем явно: так выражение
    читается однозначно, когда площадок несколько.
    """
    return "^(?:%s)$" % "|".join(escape_regex(s) for s in sites)


def group_filters(g: dict) -> list:
    """Фильтры группы: список площадок и/или ручной regex по location.

    Возвращает список пар (метка, regex). Оба ключа можно указывать вместе —
    тогда условия складываются по И (площадка и расположение одновременно).
    """
    filters = []
    if g.get("sites"):
        filters.append(("site", sites_matcher(g["sites"])))
    if g.get("location_filter"):
        filters.append(("location", g["location_filter"]))
    return filters


def describe_filters(filters) -> str:
    """Человекочитаемое описание фильтров для лога."""
    if not filters:
        return "без фильтра (весь парк)"
    return " и ".join(f"{label}=~{regex!r}" for label, regex in filters)


def validate_config(cfg: dict) -> None:
    """Проверяет groups.json до обращения к Grafana.

    Ловит опечатки в названиях ключей и площадок: без этого группа молча
    получала бы доступ ко всему парку (пустой фильтр = фильтра нет).
    """
    groups = cfg.get("groups")
    if not isinstance(groups, list) or not groups:
        die("в groups.json нет непустого списка groups")

    seen = {}
    for i, g in enumerate(groups):
        where = f"groups[{i}]"
        if not isinstance(g, dict):
            die(f"{where}: ожидается объект")
        for key in ("org", "slug", "title"):
            if not isinstance(g.get(key), str) or not g[key].strip():
                die(f"{where}: не задано обязательное поле {key!r}")
        where = f"{where} ({g['slug']})"

        if g["slug"] in seen:
            die(f"{where}: slug повторяется (уже есть у «{seen[g['slug']]}») — "
                f"uid дашбордов совпадут")
        seen[g["slug"]] = g["org"]

        sites = g.get("sites")
        if sites is not None:
            if not isinstance(sites, list) or not sites:
                die(f"{where}: sites должен быть непустым списком названий площадок")
            for s in sites:
                if not isinstance(s, str) or not s.strip():
                    die(f"{where}: в sites пустое или нестроковое название площадки")
            # Площадка со звёздочкой — почти всегда попытка написать regex там,
            # где ожидается точное название: получится «ровно эта строка».
            for s in sites:
                if "*" in s or "|" in s:
                    die(f"{where}: название площадки {s!r} выглядит как regex — "
                        f"перечислите площадки точно, как в метке site в targets.yml")

        loc = g.get("location_filter")
        if loc is not None and (not isinstance(loc, str) or not loc.strip()):
            die(f"{where}: location_filter должен быть непустой строкой или null "
                f"(null или пропуск = без ограничения по location)")

        users = g.get("users") or []
        if not isinstance(users, list):
            die(f"{where}: users должен быть списком")
        for u in users:
            if not isinstance(u, dict) or not u.get("login"):
                die(f"{where}: у каждого пользователя нужен login")

        if not group_filters(g):
            log(f"    {g['org']}: фильтр не задан — группа увидит ВЕСЬ парк")


def inject_label_filter(obj, label: str, regex: str, path: str = "$") -> int:
    """Подставляет <label>=~"regex" во все matcher'ы {job="snmp"}.

    Работает рекурсивно по всему JSON дашборда: выражения панелей, запросы
    переменных. Возвращает число заменённых строк.

    Проверяем именно свой матчер, а не подстроку `<label>=~`: в дашборде уже
    есть `site=~"$site"` (переменная-фильтр), и по подстроке фильтр группы
    не подставился бы вовсе.
    """
    changed = 0
    matcher = f'{label}=~"{regex}"'
    if isinstance(obj, dict):
        for key, val in obj.items():
            if isinstance(val, str) and 'job="snmp"' in val and matcher not in val:
                obj[key] = val.replace('job="snmp"', f'job="snmp", {matcher}')
                changed += 1
            else:
                changed += inject_label_filter(val, label, regex, f"{path}.{key}")
    elif isinstance(obj, list):
        for i, val in enumerate(obj):
            changed += inject_label_filter(val, label, regex, f"{path}[{i}]")
    return changed


def inject_location_filter(obj, regex: str, path: str = "$") -> int:
    """Совместимость: фильтр по location (до появления площадок)."""
    return inject_label_filter(obj, "location", regex, path)


def retarget_links(obj, old_uid: str, new_uid: str) -> int:
    """Переписывает внутренние ссылки копии на неё саму: /d/<old> -> /d/<new>.

    Копия дашборда живёт в отдельной организации группы, где дашборда с uid
    базового (ups-overview) нет: без переадресации ссылка «Показать вкладку
    этого ИБП» ведёт в никуда (Dashboard not found). Работает рекурсивно по
    всему JSON — панельные data links, ссылки дашборда, ссылки на панели.
    Возвращает число изменённых строк.
    """
    changed = 0
    old = f"/d/{old_uid}"
    new = f"/d/{new_uid}"
    if isinstance(obj, dict):
        for key, val in obj.items():
            if isinstance(val, str) and old in val:
                obj[key] = val.replace(old, new)
                changed += 1
            else:
                changed += retarget_links(val, old_uid, new_uid)
    elif isinstance(obj, list):
        for val in obj:
            changed += retarget_links(val, old_uid, new_uid)
    return changed


def make_group_dashboard(base: dict, slug: str, title: str, regex=None,
                         *, sites=None) -> tuple:
    dash = json.loads(json.dumps(base))  # глубокая копия
    base_uid = dash.get("uid")
    dash["uid"] = f"ups-{slug}"
    dash["title"] = title
    dash["id"] = None
    dash["version"] = 0
    if "meta" in dash:
        del dash["meta"]
    # Ссылки на базовый дашборд -> на саму копию (в организации группы
    # существует только она).
    links = retarget_links(dash, base_uid, dash["uid"]) if base_uid else 0
    # Доступ группы: список площадок и/или ручной regex по location.
    filters = group_filters({"sites": sites, "location_filter": regex})
    n = 0
    if filters:
        for label, rx in filters:
            n += inject_label_filter(dash, label, rx)
        dash["tags"] = sorted(set(dash.get("tags", []) + ["group", slug]))
    return dash, n, links


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

    validate_config(cfg)

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

    def filter_matches(filters) -> "int | None":
        """Сколько ИБП попадает под фильтры группы. None — Prometheus недоступен."""
        sel = "".join(f', {label}=~"{rx}"' for label, rx in filters)
        query = f'count(up{{job="snmp"{sel}}}) or vector(0)'
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
        filters = group_filters(g)
        dash, replaced, links = make_group_dashboard(
            base_dash, g["slug"], g["title"],
            g.get("location_filter"), sites=g.get("sites"))
        target_dir = os.path.join(install_dir, "grafana", "dashboards-groups", g["slug"])
        target = os.path.join(target_dir, f"{dash['uid']}.json")
        matched = filter_matches(filters) if filters else None
        note = (f"доступ: {describe_filters(filters)}, замен: {replaced}, "
                f"ссылок на свою копию: {links}")
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
            log(f"    ! ВНИМАНИЕ: под фильтр {describe_filters(filters)} не попал ни один "
                f"ИБП — проверьте метки site/location в targets.yml (regex в PromQL "
                f"анкорится целиком, для префикса нужен суффикс .*)")

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
