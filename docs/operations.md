# Эксплуатация

## Содержание

* [Каждый день](#каждый-день)
* [Команды управления](#команды-управления)
* [Логи](#логи)
* [Сколько места занимает история](#сколько-места-занимает-история)
* [Бэкап и восстановление](#бэкап-и-восстановление)
* [Обновление и смена версий](#обновление-и-смена-версий)
* [После перезагрузки сервера](#после-перезагрузки-сервера)
* [Смена пароля Grafana](#смена-пароля-grafana)
* [Следить за самим мониторингом](#следить-за-самим-мониторингом)

## Каждый день

```bash
/opt/ups-monitoring-native/status.sh      # 30 секунд: всё ли живо и отвечает
```

Скрипт показывает: запущены ли три сервиса и отвечают ли они по HTTP, сколько
ИБП в списке, сколько правил алертов, включены ли уведомления и сколько
хранится история. Если всё в порядке — больше ничего не требуется.

Дашборд: `http://<IP-сервера>:3000` → **«ИБП — обзор»**. Сверху — доступность и
история отказов, ниже — динамика заряда, нагрузки, температуры и напряжений.

## Команды управления

| Действие | systemd | без systemd |
|---|---|---|
| Запустить | `sudo systemctl start ups-monitoring` | `./run.sh` |
| Перезапустить (применить конфиги) | `sudo systemctl restart ups-monitoring` | `./stop.sh && ./run.sh` |
| Остановить | `sudo systemctl stop ups-monitoring` | `./stop.sh` |
| Состояние | `sudo systemctl status ups-monitoring` | `./status.sh` |
| Автозапуск | `sudo systemctl enable/disable ups-monitoring` | — |

Все команды выполняются в каталоге `/opt/ups-monitoring-native`.

## Логи

| Файл | Что внутри |
|---|---|
| `data/grafana.log` | Grafana: старт, провижининг, алерты, ошибки |
| `data/prometheus.log` | Prometheus: старт, запись блоков, ошибки опроса |
| `data/snmp_exporter.log` | snmp_exporter: **каждая неудачная попытка опроса** |
| `data/snmp_exporter-N.log` | то же для шарда N (когда `SNMP_SHARDS > 1`) |
| `journalctl -u ups-monitoring` | только сообщения супервизора `run.sh` |

```bash
tail -f /opt/ups-monitoring-native/data/*.log      # наблюдать всё сразу

# кто не отвечает и почему
grep 'Error scraping' /opt/ups-monitoring-native/data/snmp_exporter*.log | tail -20
```

Рабочая конфигурация Prometheus — `data/prometheus.yml`: она собирается при
каждом запуске из `prometheus.yml` (подставляются адреса процессов
`snmp_exporter` и правила шардинга). Правки в неё вносить бессмысленно — они
исчезнут при следующем запуске; правьте исходный `prometheus.yml`.

Ротация логов настроена автоматически (`/etc/logrotate.d/ups-monitoring`):
неделя на файл, 8 архивов, сжатие. Проверить:

```bash
sudo logrotate -d /etc/logrotate.d/ups-monitoring
```

## Сколько места занимает история

История Prometheus лежит в `data/prometheus`. На одно устройство приходится
≈30 временных рядов, поэтому места уходит мало:

| Устройств | Данных в сутки | За год (примерно) |
|---|---|---|
| 10 | ~5 МБ | ~1.5 ГБ |
| 50 | ~25 МБ | ~8 ГБ |
| 200 | ~100 МБ | ~30 ГБ |

Ориентируйтесь на реальные цифры: `du -sh /opt/ups-monitoring-native/data/prometheus`.

Как изменить срок хранения — в `.env` (нужен перезапуск):

```ini
RETENTION_TIME=1y        # 15d, 90d, 1y, 5y
RETENTION_SIZE=10GB      # необязательное ограничение по объёму
```

Проверка: `./status.sh` показывает «хранение истории Prometheus: …», либо

```bash
curl -s localhost:9090/api/v1/status/flags | jq -r '.data."storage.tsdb.retention.time"'
```

## Бэкап и восстановление

Стоит сохранять (это небольшой набор файлов — секунды на копирование):

| Что | Зачем |
|---|---|
| `.env` | пароль Grafana, токен Telegram, порты |
| `targets.yml` | список ИБП — единственная копия инвентаря |
| `snmp.yml` | community/SNMP v3, набор OID |
| `grafana/provisioning/` | правила алертов, уведомления, источники данных |
| `grafana/dashboards/` | дашборд (если правили через UI) |

Историю метрик (`data/prometheus`) и базу Grafana (`data/grafana`) бэкапить
обычно не нужно — после восстановления они наполнятся заново.

```bash
# бэкап конфигов
sudo tar czf /root/ups-config-$(date +%F).tar.gz -C /opt/ups-monitoring-native \
     .env targets.yml snmp.yml prometheus.yml grafana

# восстановление на чистой машине
curl -fsSL .../install.sh | sudo bash -s -- --yes --no-start
sudo tar xzf /root/ups-config-2026-01-01.tar.gz -C /opt/ups-monitoring-native
sudo systemctl restart ups-monitoring
```

## Обновление и смена версий

Обновление кода и конфигов — повторным запуском установщика (см.
[install.md](install.md#обновление)).

Версии бинарников заданы в начале `run.sh`:

```bash
SNMP_VER="0.26.0"
PROM_VER="3.1.0"
GF_VER="11.5.1"
```

Чтобы обновиться до новых версий: поменяйте их в репозитории (или прямо на
сервере), удалите соответствующий каталог в `bin/` и перезапустите — `run.sh`
скачает новую версию:

```bash
sudo rm -rf /opt/ups-monitoring-native/bin/prometheus-3.1.0.linux-amd64
sudo vi /opt/ups-monitoring-native/run.sh          # PROM_VER="3.2.0"
sudo systemctl restart ups-monitoring
```

Бинарники скачиваются с официальных источников (GitHub Releases Prometheus и
dl.grafana.com). Установщик дополнительно сверяет sha256; `run.sh` при
самостоятельной загрузке — нет, поэтому после установки новых версий через
`run.sh` проверьте логи: сервис должен подняться и отвечать (`./status.sh`).

## После перезагрузки сервера

Ничего делать не нужно: systemd поднимает стек автоматически
(`systemctl is-enabled ups-monitoring` → `enabled`). Проверка после ребута:

```bash
systemctl status ups-monitoring --no-pager
/opt/ups-monitoring-native/status.sh
```

Первый опрос всех ИБП происходит в течение минуты после старта (плюс время на
загрузку истории из базы).

## Смена пароля Grafana

```bash
sudo sed -i 's|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=НовыйПароль|' \
     /opt/ups-monitoring-native/.env
sudo systemctl restart ups-monitoring
```

Пароль применяется к пользователю `admin` (или тому, что в `GRAFANA_ADMIN_USER`)
при старте. Если пароль меняли и в интерфейсе, файл `.env` всё равно остаётся
источником истины при следующем старте.

## Следить за самим мониторингом

Если упадёт сервер мониторинга, об этом никто не узнает — ни один алерт не
уйдёт. Простое решение: внешняя проверка с другой машины.

```bash
# с любого другого сервера: раз в 5 минут проверяем, что мониторинг отвечает
*/5 * * * * curl -fsS --max-time 10 http://ups-host:3000/api/health >/dev/null \
            || echo "UPS monitoring недоступен" | mail -s "ALERT" admin@example.com
```

Более правильный вариант — второй Prometheus (или Zabbix/другой мониторинг) с
запросом `up{job="snmp"} == 0` по этому серверу.
