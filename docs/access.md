# Доступ: страницы мониторинга для групп «только чтение»

Как дать разным подразделениям (инженеры, операторы смены, служба слаботочных
систем) **свою страницу мониторинга** так, чтобы они ничего не могли изменить.

## Содержание

* [Что получится](#что-получится)
* [Как это устроено](#как-это-устроено)
* [Подготовка](#подготовка)
* [Настройка групп](#настройка-групп)
* [Запуск](#запуск)
* [Проверка](#проверка)
* [Добавить человека позже](#добавить-человека-позже)
* [Обслуживание](#обслуживание)
* [Справочник по API Grafana](#справочник-по-api-grafana)
* [Ограничения](#ограничения)
* [Как удалить](#как-удалить)

## Что получится

* каждая группа входит под своим логином и сразу попадает на **свою страницу**
  (свой дашборд, свой лендинг);
* видит **только свои ИБП** — по метке `location` из `targets.yml`;
* может **только смотреть**: роль `Viewer`, сохранение чего-либо недоступно;
* чужие дашборды не видны вообще (не «серые», а недоступны);
* штатный дашборд «ИБП — обзор» и админский доступ остаются как были.

## Как это устроено

| Понятие Grafana | Что означает здесь |
|---|---|
| **Организация** (Organization) | одна группа. У каждой свой набор дашбордов, свой Prometheus-датасорс и свой лендинг |
| **Папка** (Folder) | страница группы: в ней лежит её дашборд |
| **Роль** `Viewer` | «только смотреть»: без правки дашбордов, папок, алертов и датасорсов |
| **Домашний дашборд организации** | то, что открывается после входа |

Почему организации, а не команды в одной: только у организации есть собственный
домашний дашборд — то есть свой лендинг у каждой группы. Побочный плюс: у групп
не видно даже списка чужих папок.

Дашборд группы — копия штатного `grafana/dashboards/ups-overview.json`, в которой
во все запросы добавлен фильтр по метке `location`:

```
было:  count(up{job="snmp"}) or vector(0)
стало: count(up{job="snmp", location=~"Коммутационный узел.*"}) or vector(0)
```

Фильтр подставляется во **все** выражения, включая сводку по парку, таблицу
«Состояние всех ИБП» и timeline'ы — иначе группа видела бы в счётчиках весь парк.

## Подготовка

**Главное условие: у каждого ИБП в `targets.yml` должна быть метка `location`.**
Группы фильтруют именно по ней, поэтому ИБП без метки не попадёт ни в одну группу.

```yaml
- targets:
    - 10.100.165.7
  labels:
    ups_name: 'UPS-KPP6'
    location: 'Коммутационный узел КПП-6'    # ← по этому значению работает фильтр
```

Метка `location` видна в метриках (`up{location="..."}`), так что фильтровать можно
по любому её значению. Проверить, какие значения есть сейчас:

```bash
curl -s 'localhost:9090/api/v1/label/location/values' | python3 -m json.tool
```

Скрипту нужен `python3` — только ему, сам стек его не использует.

## Настройка групп

```bash
cp /opt/ups-monitoring-native/tools/grafana-groups.example.json /root/groups.json
chmod 600 /root/groups.json
nano /root/groups.json
```

```json
{
  "grafana_url": "http://localhost:3000",
  "datasource_url": null,
  "base_dashboard": "grafana/dashboards/ups-overview.json",
  "groups": [
    {
      "org": "Инженеры",
      "slug": "engineers",
      "title": "ИБП — инженерный обзор (весь парк)",
      "location_filter": null,
      "users": [{"login": "ivan.engineer", "name": "Иван Инженеров", "email": "ivan@example.local"}]
    },
    {
      "org": "Операторы",
      "slug": "operators",
      "title": "ИБП — страница смены",
      "location_filter": "Коммутационный узел.*",
      "users": [{"login": "petr.operator", "name": "Пётр Операторов", "email": "petr@example.local"}]
    }
  ]
}
```

* `org` — название организации (создастся, если нет);
* `slug` — часть имени файлов и uid дашборда (`ups-<slug>`);
* `location_filter` — какие ИБП видит группа; `null` — весь парк;
* `users` — кого завести; пароли генерируются и печатаются один раз;
* `datasource_url: null` — адрес Prometheus берётся из `PROMETHEUS_PORT` в `.env`
  (указывайте явно только если Prometheus на другом хосте).

> **Regex в PromQL анкорится целиком.** `location=~"КПП"` не найдёт `КПП-6` —
> нужен `"КПП.*"`. Для нескольких узлов: `"ЦОД-1|ЦОД-2"`. Скрипт сам проверит
> фильтр по живому Prometheus и напишет, сколько ИБП под него попало;
> `0` — почти наверняка ошибка в выражении.

## Запуск

```bash
sudo python3 /opt/ups-monitoring-native/tools/grafana-groups.py \
     --config /root/groups.json --dry-run          # посмотреть план
sudo python3 /opt/ups-monitoring-native/tools/grafana-groups.py \
     --config /root/groups.json --restart          # сделать
```

`--restart` перезапускает стек, дожидается Grafana и выставляет лендинги. Это важно:
провайдер дашбордов Grafana читает **при старте**, а домашний дашборд нельзя
поставить на ещё не подключённый дашборд. Без `--restart` запустите скрипт дважды —
до и после `systemctl restart ups-monitoring`.

Скрипт идемпотентный: повторный запуск ничего не создаёт заново и не ломает.
Другие ключи: `--dir` (каталог установки), `--url` (адрес Grafana),
`--service` (имя systemd-юнита), `--dry-run`.

Что появится в каталоге установки:

```
grafana/provisioning/datasources/groups.yml       # Prometheus-датасорс в каждой организации
grafana/provisioning/dashboards/groups.yml        # провайдер дашбордов по организациям
grafana/dashboards-groups/<slug>/ups-<slug>.json  # страница группы
```

Эти файлы — «ваши», обновление стека их не затирает: установщик копирует файлы
репозитория с перезаписью, но лишние не удаляет.

## Проверка

```bash
# лендинг каждой группы — должен быть свой дашборд
curl -s -u ЛОГИН:ПАРОЛЬ http://localhost:3000/api/dashboards/home \
  | python3 -m json.tool | grep redirectUri
```

Что должно быть у группы:

* `redirectUri` указывает на её дашборд (`/d/ups-operators/...`);
* в списке дашбордов только свой (`/api/search?type=dash-db`);
* чужой дашборд — `404`, сохранение (`POST /api/dashboards/db`) — `403`;
* роль в организации — `Viewer`;
* счётчики «Всего ИБП», таблица и вкладки показывают только устройства группы.

## Добавить человека позже

Дописать в `/root/groups.json`:

```json
{"login": "new.operator", "name": "Имя Фамилия", "email": "new@example.local"}
```

и запустить скрипт снова — пароль сгенерируется и напечатается. Существующие
аккаунты не пересоздаются.

Либо вручную: **Administration → Users and access → Users → Add user**, роль
`Viewer`, затем добавить в нужную организацию.

## Обслуживание

* **После обновления стека** (изменился `ups-overview.json`) запустите скрипт снова:
  страницы групп — копии, поэтому их надо пересобрать из новой версии.
* **Изменили состав групп или фильтр** — тот же повторный запуск.
* Чтобы запретить группам произвольные запросы в Explore (у них есть право
  `datasources:query`), добавьте в `.env` `GF_EXPLORE_ENABLED=false` и перезапустите
  стек: тогда Viewer видит только дашборды.

## Справочник по API Grafana

Проверено на Grafana 11.5.1. Пароль администратора — из `.env`:

```bash
GPASS=$(sudo grep '^GRAFANA_ADMIN_PASSWORD=' /opt/ups-monitoring-native/.env | cut -d= -f2-)
API=http://localhost:3000

# пользователь (в организации OrgId: 2,3,... роль по умолчанию — Viewer)
curl -s -u "admin:$GPASS" -H 'Content-Type: application/json' -X POST $API/api/admin/users \
  -d '{"name":"Иван","email":"ivan@example.ru","login":"ivan","password":"Str0ng-P@ss","OrgId":2}'

# роль в текущей организации (Viewer | Editor | Admin)
curl -s -u "admin:$GPASS" -H 'Content-Type: application/json' -X PATCH $API/api/org/users/2 \
  -d '{"role":"Viewer"}'

# папки и права (permission: 1=View, 2=Edit, 4=Admin)
curl -s -u "admin:$GPASS" $API/api/folders
curl -s -u "admin:$GPASS" -H 'Content-Type: application/json' -X POST \
  $API/api/folders/<folderUid>/permissions -d '{"items":[{"teamId":1,"permission":1}]}'

# список организаций
curl -s -u "admin:$GPASS" $API/api/orgs
```

## Ограничения

* Уведомления (Telegram) настраиваются один раз в Main Org. В организациях групп
  правил алертов нет: операционный статус группа видит на самой странице
  (счётчики «Нет связи», «От батареи», «Тревоги»). Дублировать правила в каждую
  организацию можно, но они будут считаться в каждой из них.
* Пароль администратора из `.env` задаёт учётку только при первом создании;
  смена пароля в интерфейсе переживает перезапуск (проверено на 11.5.1).
* Тонких кастомных ролей в Grafana OSS нет (это Enterprise) — используются
  базовые роли и права папок.

## Как удалить

```bash
rm -f /opt/ups-monitoring-native/grafana/provisioning/datasources/groups.yml
rm -f /opt/ups-monitoring-native/grafana/provisioning/dashboards/groups.yml
rm -rf /opt/ups-monitoring-native/grafana/dashboards-groups
sudo systemctl restart ups-monitoring
```

Организации и аккаунты удаляются в интерфейсе: **Server Admin → Organizations**.
