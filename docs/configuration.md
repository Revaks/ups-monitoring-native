# Настройка

## Содержание

* [Что в каком файле и когда применяется](#что-в-каком-файле-и-когда-применяется)
* [.env — настройки и секреты](#env--настройки-и-секреты)
* [Каталоги на дисках и ротация логов](#каталоги-на-дисках-и-ротация-логов)
* [targets.yml — список ИБП](#targetsyml--список-ибп)
* [Инвентарь из таблицы (CSV)](#инвентарь-из-таблицы-csv)
* [snmp.yml — как опрашивать ИБП](#snmpyml--как-опрашивать-ибп)
* [SNMP v3 и разные учётки в одном пуле](#snmp-v3-и-разные-учётки-в-одном-пуле)
* [Интервал опроса, таймауты, пороги](#интервал-опроса-таймауты-пороги)
* [Как убедиться, что настройка применилась](#как-убедиться-что-настройка-применилась)

## Что в каком файле и когда применяется

| Файл | Что настраивает | Когда применяется |
|---|---|---|
| `.env` | порты, адрес прослушивания, пароль Grafana, токен Telegram, хранение истории, число процессов опроса (`SNMP_SHARDS`), каталоги на дисках (`DATA_DIR`/`LOG_DIR`), ротация логов (`LOG_*`) | после **перезапуска** стека |
| `targets.yml` | список ИБП и их метки | автоматически, ≤30 секунд |
| `snmp.yml` | OID, community, SNMP v3, таймауты | после **перезапуска** стека |
| `prometheus.yml` | интервал опроса, правила разметки метрик, блок шардинга | после **перезапуска** стека |
| `grafana/dashboards/*.json` | панели дашборда | автоматически, ≤30 секунд |
| `grafana/provisioning/alerting/*` | правила алертов, уведомления | после **перезапуска** стека |

Один нюанс про `prometheus.yml`: `run.sh` при каждом запуске собирает из него
рабочую копию `data/prometheus.yml` — подставляет адреса процессов
`snmp_exporter`, правила шардинга и абсолютный путь к `targets.yml`. Prometheus
запускается именно с этой копией, поэтому правьте исходный `prometheus.yml`.

Перезапуск: `sudo systemctl restart ups-monitoring`
(или `./stop.sh && ./run.sh` при ручном запуске).

## .env — настройки и секреты

Файл лежит рядом со скриптами (`/opt/ups-monitoring-native/.env`), права `600`,
создаётся установщиком. Полный список с пояснениями — в `.env.example`.

```ini
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=Str0ng-Pass

TELEGRAM_BOT_TOKEN=          # пусто = уведомления выключены
TELEGRAM_CHAT_ID=

LISTEN_ADDR=0.0.0.0          # 127.0.0.1 — только локально (docs/security.md)
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
SNMP_EXPORTER_PORT=9116
SNMP_SHARDS=1                # 1 процесс опроса; 2..8 — шардинг (docs/scaling.md)

RETENTION_TIME=1y            # 15d, 90d, 1y, 5y
RETENTION_SIZE=              # например 10GB, пусто — без ограничения

#DATA_DIR=/mnt/disk1/ups-monitoring      # история, база Grafana, pid-файлы
#LOG_DIR=/mnt/disk2/ups-monitoring-logs  # логи (по умолчанию — как DATA_DIR)
LOG_MAX_SIZE=10M             # предел размера одного лога (0 — не ограничивать)
LOG_KEEP_PERCENT=10          # сколько % хвоста оставить при обрезке
LOG_CHECK_INTERVAL=10        # как часто ротатор проверяет размеры, сек
```

Как поменять: откройте `.env`, поправьте строку, перезапустите стек.

```bash
sudo vi /opt/ups-monitoring-native/.env
sudo systemctl restart ups-monitoring
/opt/ups-monitoring-native/status.sh
```

> Свой `.env` можно сгенерировать из шаблона: `cp .env.example .env`.

## Каталоги на дисках и ротация логов

Две вещи, которые чаще всего приходится настраивать на реальном сервере: куда
пишутся данные (история и логи) и как логи не съедают диск.

**Каталоги.** По умолчанию всё лежит в `<каталог установки>/data`. Имя каталога
меняется через `.env` (или при установке — флагами `--data-dir` и `--log-dir`):

```ini
DATA_DIR=/mnt/disk1/ups-monitoring       # TSDB Prometheus, база Grafana, pid-файлы
LOG_DIR=/mnt/disk2/ups-monitoring-logs   # логи сервисов
```

`LOG_DIR` по умолчанию равен `DATA_DIR`. Смысл разносить: на быстром диске
держат то, что постоянно пишется (TSDB Prometheus), а логи — где угодно, они
ограничены по размеру. Подробности, перенос уже накопленных данных и типичная
ошибка «диск не смонтирован» — в
[docs/operations.md](operations.md#данные-и-логи-на-разных-дисках).

**Ротация логов по размеру.** `run.sh` поднимает фоновый ротатор, который
проверяет размеры файлов в `LOG_DIR`. Достигнув `LOG_MAX_SIZE`, файл обрезается
на месте: самое старое стирается, а хвост (`LOG_KEEP_PERCENT` % от предела)
остаётся. Сервис при этом не перезапускается — логи открыты в режиме `O_APPEND`.

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `LOG_MAX_SIZE` | `10M` | предел размера одного файла; `0` — не ограничивать |
| `LOG_KEEP_PERCENT` | `10` | сколько процентов хвоста оставить при обрезке (`0` — обнулять) |
| `LOG_CHECK_INTERVAL` | `10` | период проверки в секундах (минимум 5) |

Обрезать вручную в любой момент: `./run.sh --rotate-now` (годится и для
cron/systemd-таймера, если ротатор почему-то не запущен). Раздел «Ротация логов
по размеру» в [docs/operations.md](operations.md#ротация-логов-по-размеру)
описывает поведение подробнее, включая «перелёт» за предел у болтливых сервисов.

## targets.yml — список ИБП

Файл из двух полей: адрес устройства и необязательные метки.

```yaml
# короткая запись
- targets: [192.168.1.10]
  labels: {site: 'Площадка №1', ups_name: 'UPS-01', location: 'Узел №1'}

# то же самое в многострочном виде (как пишет install.sh)
- targets:
    - 192.168.1.11
  labels:
    site: 'Площадка №1'
    ups_name: 'UPS-02'
    location: 'Узел №2'
```

Метки:

| Метка | Зачем | Пример |
|---|---|---|
| `site` | **территория (площадка, филиал)** — по ней группы подразделений видят только свои ИБП, см. [access.md](access.md) | `Площадка №1` |
| `ups_name` | имя ИБП — попадает в `instance`, его видно на дашборде и в алертах. **Должно быть уникальным** | `UPS-01` |
| `location` | расположение внутри площадки: узел, шкаф, ряд, этаж | `ЦОД-1, стойка A` |
| `snmp_auth` | имя учётки из `snmp.yml`, если у устройства другой community или SNMP v3 | `dc_v3` |
| `snmp_module` | имя модуля из `snmp.yml`, если нужен другой набор OID | `ups_vendor` |
| `ups_segment` | сегмент сети для шардинга опроса ([scaling.md](scaling.md)); к правам доступа отношения не имеет | `dc2` |

Про `site` — территория отличается от `location`:

* `site` отвечает на вопрос «кто это должен видеть», `location` — «где это стоит»;
* значение точное, а не шаблон: `Площадка №1` и `площадка 1` — **разные**
  территории, пишите название одинаково у всех ИБП одной площадки;
* ИБП без метки `site` не попадёт ни в одну группу со списком площадок. На
  дашборде он виден при выборе «All» в переменной «Площадка».

Важно про `instance`: если `ups_name` задано — на дашборде и в алертах
устройство называется по имени, а его адрес виден в отдельной метке `ups_ip`.
Если имени нет — `instance` остаётся IP-адресом. Поэтому при смене IP
устройства с заданным именем история не теряется.

Вместо IP можно указать `IP:порт` — если SNMP у ИБП на нестандартном порту
(по умолчанию 161).

Добавить устройство:

```bash
sudo vi /opt/ups-monitoring-native/targets.yml     # допишите запись
# через ≤30 секунд проверьте:
curl -s localhost:9090/api/v1/query?query=up | jq -r '.data.result[] | "\(.metric.instance) \(.metric.up)"'
```

## Инвентарь из таблицы (CSV)

Если устройств много, список удобнее вести в таблице (Excel, NetBox, CMDB) и
генерировать `targets.yml` из неё:

```bash
# формат с шапкой: колонки можно переставлять и указывать не все.
# Обязательна только ip. site — территория (см. «Права групп» в access.md).
cat > inventory.csv <<'EOF'
ip;site;name;location;snmp_auth
192.168.1.10;Площадка №1;UPS-01;Коммутационный узел №1
192.168.1.11;Площадка №1;UPS-02;Коммутационный узел №2
10.0.0.5;ЦОД-1;UPS-DC1;ЦОД-1, ряд 3;dc_v3
EOF

/opt/ups-monitoring-native/tools/targets-from-csv.sh inventory.csv          # записать
/opt/ups-monitoring-native/tools/targets-from-csv.sh inventory.csv --check  # только проверить
```

Старый позиционный формат без шапки поддерживается и работает как раньше:

```
IP[:порт];имя;расположение[;snmp_auth[;snmp_module[;site]]]
```

Скрипт проверит адреса, найдёт дубликаты IP и имён (имена должны быть
уникальными), покажет, сколько получилось площадок, и запишет файл в формате,
который понимает Prometheus. Пример таблицы — `tools/inventory.example.csv`.

> **`targets.yml` перезаписывается целиком.** Если вы правили его руками,
> перенесите правки в инвентарь: метки, которых нет в CSV, в новый файл не
> попадут. Скрипт предупредит, если в инвентаре нет ни одной площадки.

## snmp.yml — как опрашивать ИБП

### Сменить community для всех ИБП

```yaml
auths:
  public_v2:
    version: 2
    community: public        # ← ваше значение
```

Перезапустите стек. То же самое умеет установщик: `--community 'myCommunity'`.

### SNMP v3 и разные учётки в одном пуле

Добавьте свой блок в `auths:` и укажите его имя в метке устройства:

```yaml
auths:
  public_v2: { version: 2, community: public, ... }
  dc_v3:
    version: 3
    security_level: authPriv          # noAuthNoPriv | authNoPriv | authPriv
    username: upsmon
    password: "Auth-Pass"
    auth_protocol: SHA                # MD5, SHA, SHA256, SHA512
    priv_protocol: AES                # DES, AES, AES192, AES256
    priv_password: "Priv-Pass"
    context_name: ""
```

```yaml
# targets.yml
- targets: [10.0.0.5]
  labels: {ups_name: 'UPS-DC1', location: 'ЦОД-1', snmp_auth: 'dc_v3'}
```

Чтобы не хранить пароли в `snmp.yml`, положите их в `.env` (например
`SNMP_V3_PASSWORD=...`) и напишите в `snmp.yml` `password: ${SNMP_V3_PASSWORD}` —
`run.sh` запускает snmp_exporter с поддержкой подстановки переменных окружения.
Файл `snmp.yml` при этом стоит закрыть: `chmod 600 snmp.yml`.

### Что опрашивается

Метрики стандартного UPS-MIB (RFC 1628), одинаковые названия у большинства
производителей:

| Группа | Метрики |
|---|---|
| Батарея | `upsBatteryStatus`, `upsSecondsOnBattery`, `upsEstimatedMinutesRemaining`, `upsEstimatedChargeRemaining`, `upsBatteryVoltage`, `upsBatteryCurrent`, `upsBatteryTemperature` |
| Вход | `upsInputVoltage`, `upsInputCurrent`, `upsInputFrequency`, `upsInputTruePower` (по линиям) |
| Выход | `upsOutputVoltage`, `upsOutputCurrent`, `upsOutputPower`, `upsOutputPercentLoad` (по линиям), `upsOutputSource`, `upsOutputFrequency` |
| Идентификация* | `upsIdentManufacturer`, `upsIdentModel`, `upsIdentUPSSoftwareVersion`, `upsIdentAgentSoftwareVersion`, `upsIdentName` |
| Дополнительно* | `upsInputLineBads` (сколько раз пропадало питание), `upsAlarmsPresent` (число тревог) |

\* помеченные группы есть не у всех ИБП. Они опрашиваются обходом (walk), поэтому
устройство без этих OID продолжает нормально опрашиваться — просто этих метрик
у него не будет. **Не переносите их в `get:`**: запрос GET со списком OID, среди
которых есть отсутствующий, возвращает ошибку noSuchName и весь опрос устройства
падает (`up=0`).

`upsIdentManufacturer` и `upsIdentName` собираются, но плиток для них на дашборде
нет: у многих моделей эти OID пустые, поэтому плитки выводили служебное имя серии
Prometheus вместо значения. Нужна строка — смотрите метрику в Explore.

## Интервал опроса, таймауты, пороги

**Интервал** — в `prometheus.yml` (нужен перезапуск):

```yaml
global:
  scrape_interval: 1m          # как часто опрашивать ИБП
  scrape_timeout: 30s          # сколько ждать ответа на один опрос
```

**Таймауты SNMP** — в конце модуля `ups` в `snmp.yml`:

```yaml
    max_repetitions: 25
    retries: 1                 # сколько повторов на запрос
    timeout: 2s                # ожидание ответа на один запрос
```

Худшее время опроса недоступного ИБП = `timeout × (retries + 1)` = 4 секунды.
Если устройств много или сеть медленная, смотрите [scaling.md](scaling.md).

**Пороги алертов** (заряд, нагрузка, температура, время) — в
`grafana/provisioning/alerting/rules.yml`, см. [alerts.md](alerts.md).

## Как убедиться, что настройка применилась

```bash
# 1. Общее состояние: запущено ли, отвечает ли
/opt/ups-monitoring-native/status.sh

# 2. Какие ИБП Prometheus видит и с какими метками
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.instance) \(.health)"'

# 3. Опросить конкретный ИБП вручную (по SNMP, минуя Prometheus)
curl 'http://localhost:9116/snmp?module=ups&target=192.168.1.10&auth=public_v2'

# 4. Что Prometheus успел собрать
curl -s 'localhost:9090/api/v1/query?query=upsEstimatedChargeRemaining'
```

Если метки не появились, а `health=down` — смотрите
[troubleshooting.md](troubleshooting.md).
