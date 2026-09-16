# UPS Monitoring — без Docker

Тот же мониторинг ИБП по SNMP (UPS-MIB, RFC 1628), но **без Docker**:
`snmp_exporter` + `Prometheus` + `Grafana` запускаются как обычные процессы.

Единственная зависимость — `bash` и `curl` (для первого скачивания бинарников).
Ни Python, ни Docker, ни пакетные менеджеры не нужны.

## Структура

```
ups-monitoring-native/
├── run.sh            # скачать бинарники + запустить всё
├── stop.sh           # остановить всё
├── prometheus.yml    # конфиг Prometheus
├── targets.yml       # ← СПИСОК ИБП (IP добавлять сюда)
├── snmp.yml          # модуль "ups" для snmp_exporter (OID + community)
└── grafana/
    ├── provisioning/ # авто-подключение источника и дашборда
    └── dashboards/ups-overview.json
```

`bin/` (бинарники) и `data/` (БД/логи) создаются автоматически и не входят в git.

## Запуск

1. Впишите IP своих ИБП в `targets.yml`.
2. (Опционально) задайте логин/пароль Grafana:
   ```bash
   export GRAFANA_ADMIN_USER=admin
   export GRAFANA_ADMIN_PASSWORD=yourpassword
   ```
   По умолчанию `admin` / `admin`.
3. Запустите:
   ```bash
   ./run.sh
   ```

Скрипт сам скачает нужные версии бинарников (snmp_exporter 0.26.0,
Prometheus 3.1.0, Grafana 11.5.1) и запустит их в фоне.

| Сервис        | URL                          |
|---------------|------------------------------|
| Grafana       | http://localhost:3000        |
| Prometheus    | http://localhost:9090        |
| snmp_exporter | http://localhost:9116        |

Дашборд **«ИБП — обзор»** создаётся автоматически.

## Остановка

```bash
./stop.sh
```

## Смена community / SNMP v3

Откройте `snmp.yml` (блок `auths.public_v2.community`) и перезапустите:

```bash
./stop.sh && ./run.sh
```

## Диагностика

```bash
# проверить опрос конкретного ИБП напрямую:
curl 'http://localhost:9116/snmp?module=ups&target=<IP_ИБП>'

# логи:
tail -f data/prometheus.log data/snmp_exporter.log data/grafana.log
```

## ARM / другие платформы

Скрипт по умолчанию рассчитан на `linux-amd64`. Для ARM (Raspberry Pi и т.п.)
поменяйте `ARCH` в `run.sh` на `linux-arm64` и при необходимости версии.
