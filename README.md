# UPS Monitoring — без Docker

Мониторинг ИБП по SNMP: `snmp_exporter` + `Prometheus` + `Grafana` запускаются
обычными процессами. Нужны только `bash`, `curl`, `tar` — ни Docker, ни Python,
ни пакетные менеджеры.

Опрашиваются стандартные метрики UPS-MIB (RFC 1628), которые отдают сетевые
карты большинства ИБП: APC, Eaton, CyberPower, Delta, Ippon и др.

**Что вы получите:**

* дашборд **«ИБП — обзор»**: заряд и температура батареи, нагрузка, входное и
  выходное напряжение, остаток автономной работы, доступность каждого ИБП и
  история «когда работал от батареи»;
* **7 алертов**: недоступен по SNMP, работа от батареи, низкий заряд, мало
  времени автономии, перегрузка, перегрев, медленный опрос — с отправкой в
  Telegram (по умолчанию выключено, включается одной строкой в `.env`);
* **пул устройств в одном файле**: чтобы добавить ИБП, достаточно одной записи
  в `targets.yml` — перезапуск не нужен;
* **рост без переделки**: `SNMP_SHARDS=2` в `.env` — и опрос распределяется
  между несколькими процессами `snmp_exporter` (см.
  [docs/scaling.md](docs/scaling.md)).

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh | sudo bash
```

Установщик спросит IP ваших ИБП и пароль Grafana, разложит стек в
`/opt/ups-monitoring-native`, скачает бинарники с проверкой sha256, включит
автозапуск через systemd и проверит, что ИБП отвечает по SNMP.

Без вопросов:

```bash
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh \
  | sudo bash -s -- --yes \
      --targets '192.168.1.10:UPS-01:Коммутационный узел №1,192.168.1.11:UPS-02' \
      --password 'Str0ng-Pass'
```

Дальше откройте Grafana (`http://<IP-сервера>:3000`) — дашборд **«ИБП — обзор»**
подключён автоматически.

## Управление

```bash
/opt/ups-monitoring-native/status.sh      # что запущено, отвечает ли, сколько ИБП
sudo systemctl restart ups-monitoring     # перезапустить стек
sudo systemctl stop ups-monitoring        # остановить
tail -n 50 /opt/ups-monitoring-native/data/*.log    # логи
```

Если systemd не используется (ручной запуск): `./run.sh`, `./stop.sh`, `./status.sh`.

## Версии, обновление и откат

Каждая версия помечена тегом в git, поэтому любую — включая предыдущую — можно
поставить одной командой:

```bash
# установить конкретную версию (тег из CHANGELOG.md)
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh \
  | sudo bash -s -- --yes --ref v1.0.0

# вернуться на последнюю разработку
... | sudo bash -s -- --yes --ref main
```

Если версия настолько старая, что текущий установщик её не понимает (менялась
структура проекта), возьмите установщик из того же тега — он всегда
самосогласован:

```bash
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/v1.0.0/install.sh \
  | sudo bash -s -- --yes --ref v1.0.0
```

Что при этом сохраняется: `.env`, `targets.yml` и каталог `data/` (история
Prometheus и база Grafana). Поэтому откат версии не теряет настройки и данные.

Установщик запоминает установленную версию в `.installed-ref`: повторный запуск
**без** `--ref` остаётся на ней, а не «уезжает» на `main`. Посмотреть, что
установлено:

```bash
cat /opt/ups-monitoring-native/.installed-ref      # текущая версия
/opt/ups-monitoring-native/status.sh
```

Список версий и что в них менялось: [CHANGELOG.md](CHANGELOG.md) и
[Releases](https://github.com/Revaks/ups-monitoring-native/releases)
(оттуда же можно скачать архив любой версии вручную).

## Документация

| Документ | О чём |
|---|---|
| [docs/install.md](docs/install.md) | установка, обновление, удаление, запуск без systemd |
| [docs/configuration.md](docs/configuration.md) | список ИБП, community и SNMP v3, порты, хранение истории |
| [docs/alerts.md](docs/alerts.md) | все правила, пороги, уведомления в Telegram, тишина |
| [docs/operations.md](docs/operations.md) | ежедневная эксплуатация: логи, бэкап, обновление версий |
| [docs/troubleshooting.md](docs/troubleshooting.md) | «нет данных», «ИБП недоступен», «порт занят» и другие симптомы |
| [docs/scaling.md](docs/scaling.md) | сколько выдержит один сервер, шардинг, инвентарь из CSV |
| [docs/security.md](docs/security.md) | закрыть лишние порты, пароли и секреты |
| [CHANGELOG.md](CHANGELOG.md) | что менялось от версии к версии |
| [ROADMAP.md](ROADMAP.md) | что уже сделано и что в планах |

## Структура

```
ups-monitoring-native/
├── install.sh        # установщик для сервера (см. docs/install.md)
├── run.sh            # запуск стека (--foreground — режим супервизора для systemd)
├── stop.sh           # аккуратная остановка (SIGTERM → ожидание → SIGKILL)
├── status.sh         # что запущено и отвечает ли
├── prometheus.yml    # конфиг Prometheus (список ИБП читается из targets.yml)
├── targets.yml       # ← СПИСОК ИБП (IP, имена, расположения)
├── snmp.yml          # модуль "ups" для snmp_exporter: OID, community, таймауты
├── .env              # секреты и настройки портов (создаёт install.sh, права 600)
├── .installed-ref    # какая версия (тег) установлена на сервере
├── CHANGELOG.md      # что менялось от версии к версии
├── ROADMAP.md        # очередь доработок
├── docs/             # документация
├── tools/
│   ├── targets-from-csv.sh      # собрать targets.yml из таблицы инвентаря
│   └── inventory.example.csv    # пример такой таблицы
└── grafana/
    ├── provisioning/
    │   ├── datasources/   # источник данных Prometheus
    │   ├── dashboards/    # авто-подключение дашборда
    │   └── alerting/      # правила алертов, политика, шаблоны уведомлений
    └── dashboards/ups-overview.json
```

`bin/` (бинарники) и `data/` (база Prometheus, Grafana, логи, pid-файлы)
создаются автоматически и в git не попадают.

## Как это работает

```
                    Prometheus ── scrape /snmp?target=… ──► snmp_exporter ──SNMP/UDP 161──► ИБП
                        │                                     (модуль ups)
                        │  хранит историю (RETENTION_TIME)
                        ▼
   Grafana ◄─────────┘  дашборд + правила алертов → Telegram
```

Prometheus раз в минуту обращается к `snmp_exporter`, тот по SNMP опрашивает
ИБП. Список устройств Prometheus берёт из `targets.yml` и перечитывает его
каждые 30 секунд. Grafana показывает данные и считает алерты.

## Требования

* Linux с systemd (Debian/Ubuntu, RHEL/Fedora, Arch и производные);
* `bash`, `curl`, `tar`, `sha256sum` — для установки; `systemd-analyze` не нужен;
* архитектуры: `amd64`, `arm64`, `armv7`, `armv6` (меняется автоматически);
* доступ по UDP/161 от сервера мониторинга до ИБП, SNMP включён в веб-интерфейсе ИБП.

Порты на сервере: Grafana 3000, Prometheus 9090, snmp_exporter 9116 — все
меняются через `.env`, см. [docs/configuration.md](docs/configuration.md).
