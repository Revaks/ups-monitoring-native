# Настройка

## Содержание

* [Что в каком файле и когда применяется](#что-в-каком-файле-и-когда-применяется)
* [.env — настройки и секреты](#env--настройки-и-секреты)
* [targets.yml — список ИБП](#targetsyml--список-иБП)
* [Инвентарь из таблицы (CSV)](#инвентарь-из-таблицы-csv)
* [snmp.yml — как опрашивать ИБП](#snmpyml--как-опрашивать-иБП)
* [SNMP v3 и разные community](#snmp-v3-и-разные-community)
* [Интервал опроса, таймауты, пороги](#интервал-опроса-таймауты-пороги)
* [Как убедиться, что настройка применилась](#как-убедиться-что-настройка-применилась)

## Что в каком файле и когда применяется

| Файл | Что настраивает | Когда применяется |
|---|---|---|
| `.env` | порты, адрес прослушивания, пароль Grafana, токен Telegram, хранение истории | после **перезапуска** стека |
| `targets.yml` | список ИБП и их метки | автоматически, ≤30 секунд |
| `snmp.yml` | OID, community, SNMP v3, таймауты | после **перезапуска** стека |
| `prometheus.yml` | интервал опроса, правила разметки метрик | после **перезапуска** стека |
| `grafana/dashboards/*.json` | панели дашборда | автоматически, ≤30 секунд |
| `grafana/provisioning/alerting/*` | правила алертов, уведомления | после **перезапуска** стека |

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

RETENTION_TIME=1y            # 15d, 90d, 1y, 5y
RETENTION_SIZE=              # например 10GB, пусто — без ограничения
```

Как поменять: откройте `.env`, поправьте строку, перезапустите стек.

```bash
sudo vi /opt/ups-monitoring-native/.env
sudo systemctl restart ups-monitoring
/opt/ups-monitoring-native/status.sh
```

> Свой `.env` можно сгенерировать из шаблона: `cp .env.example .env`.

## targets.yml — список ИБП

Файл из двух полей: адрес устройства и необязательные метки.

```yaml
# короткая запись
- targets: [192.168.1.10]
  labels: {ups_name: 'UPS-01', location: 'Узел №1'}

# то же самое в многострочном виде (как пишет install.sh)
- targets:
    - 192.168.1.11
  labels:
    ups_name: 'UPS-02'
    location: 'Узел №2'
```

Метки:

| Метка | Зачем | Пример |
|---|---|---|
| `ups_name` | имя ИБП — попадает в `instance`, его видно на дашборде и в алертах. **Должно быть уникальным** | `UPS-01` |
| `location` | расположение/узел, удобно фильтровать | `ЦОД-1, стойка A` |
| `snmp_auth` | имя учётки из `snmp.yml`, если у устройства другой community или SNMP v3 | `dc_v3` |
| `snmp_module` | имя модуля из `snmp.yml`, если нужен другой набор OID | `ups_vendor` |

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
# формат: IP[:порт];имя;расположение[;snmp_auth[;snmp_module]]
cat > inventory.csv <<'EOF'
192.168.1.10;UPS-01;Коммутационный узел №1
192.168.1.11;UPS-02;Коммутационный узел №2
10.0.0.5;UPS-DC1;ЦОД-1;dc_v3
EOF

/opt/ups-monitoring-native/tools/targets-from-csv.sh inventory.csv          # записать
/opt/ups-monitoring-native/tools/targets-from-csv.sh inventory.csv --check  # только проверить
```

Скрипт проверит адреса, найдёт дубликаты IP и имён (имена должны быть
уникальными) и запишет файл в формате, который понимает Prometheus. Пример
таблицы — `tools/inventory.example.csv`.

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
