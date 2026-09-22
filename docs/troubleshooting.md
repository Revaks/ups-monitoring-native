# Что делать, если что-то не работает

Начните с двух команд — они отвечают на большинство вопросов:

```bash
/opt/ups-monitoring-native/status.sh                       # что запущено и отвечает ли
tail -n 30 /opt/ups-monitoring-native/data/*.log           # что сервисы говорят
```

## Содержание

* [Все ИБП показывают «НЕДОСТУПЕН» или нет данных](#все-ИБП-показывают-недоступен-или-нет-данных)
* [Один ИБП недоступен, остальные работают](#один-ИБП-недоступен-остальные-работают)
* [Метрик меньше, чем ожидалось](#метрик-меньше-чем-ожидалось)
* [Данные есть, но не появились именам/расположения](#данные-есть-но-не-появились-именамирасположения)
* [Порт занят при запуске](#порт-занят-при-запуске)
* [Grafana не открывается](#grafana-не-открывается)
* [Алерты не приходят в Telegram](#алерты-не-приходят-в-telegram)
* [Правила алертов не появились в Grafana](#правила-алертов-не-появились-в-grafana)
* [Опрос стал медленным, в логах таймауты](#опрос-стал-медленным-в-логах-таймауты)
* [Шардинг: шарды не распределяют или не поднимаются](#шардинг-шарды-не-распределяют-или-не-поднимаются)
* [Пропала история по устройству](#пропала-история-по-устройству)
* [Растёт диск](#растёт-диск)
* [Правка конфига не применилась](#правка-конфига-не-применилась)
* [Что собрать, если нужна помощь](#что-собрать-если-нужна-помощь)

## Все ИБП показывают «НЕДОСТУПЕН» или нет данных

1. Проверьте, что сервисы живы:

   ```bash
   /opt/ups-monitoring-native/status.sh
   ```

   Если сервис `ОСТАНОВЛЕН` — смотрите его лог в `data/*.log` и запустите стек
   заново: `sudo systemctl restart ups-monitoring`.

2. Проверьте опрос одного ИБП напрямую (это ответит на вопрос «сервисы или сеть»):

   ```bash
   curl 'http://localhost:9116/snmp?module=ups&target=192.168.1.10&auth=public_v2'
   ```

   * пришли строки с `upsBatteryStatus`, `upsEstimatedChargeRemaining` … — SNMP
     работает, проблема в Prometheus/Grafana: смотрите `data/prometheus.log`;
   * `Error scraping target … request timeout` — ИБП не отвечает: сеть, firewall,
     SNMP выключен на ИБП (см. ниже);
   * `error reported by target … Error Status 2` — SNMP отвечает, но **не тот
     community** (или другой SNMP-параметр).

3. Проверьте «глазами Prometheus», какие цели и с каким состоянием:

   ```bash
   curl -s localhost:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | "\(.labels.instance) \(.health) \(.lastError)"'
   ```

   `lastError` обычно объясняет причину.

## Один ИБП недоступен, остальные работают

```bash
ping -c2 192.168.1.10                     # есть ли сеть до устройства
nc -zu 192.168.1.10 161                   # открыт ли UDP/161 (молчание = «нет ответа»)
curl 'http://localhost:9116/snmp?module=ups&target=192.168.1.10&auth=public_v2'
```

Типичные причины:

| Симптом в ответе | Причина | Что делать |
|---|---|---|
| `request timeout` | SNMP выключен, неверный IP, ACL на ИБП, устройство за firewall | включить SNMP в веб-интерфейсе ИБП, проверить ACL/адрес |
| `Error Status 2` | не тот community | поправить `community` в `snmp.yml` или задать свою учётку через `snmp_auth` |
| `unsupported security level` | у ИБП SNMP v1/v3, а мы опрашиваем v2c | настроить соответствующий блок `auths` и метку `snmp_auth` |
| Все ИБП узла недоступны | упал коммутатор/узел | проверить сеть узла |

После правки `snmp.yml` нужен перезапуск: `sudo systemctl restart ups-monitoring`.
Учтите: алерт «недоступен» ждёт 3 минуты, чтобы не спамить на разовых таймаутах.

## Метрик меньше, чем ожидалось

Это нормально. Идентификация (`upsIdentManufacturer`, `upsIdentModel`, …) и
`upsAlarmsPresent` есть не у всех ИБП — они опрашиваются обходом, и у устройств
без этих OID метрик просто не будет. Устройство при этом нормально опрашивается
(`up = 1`).

Если хочется знать, что именно отдаёт конкретный ИБП:

```bash
curl -s 'http://localhost:9116/snmp?module=ups&target=192.168.1.10&auth=public_v2' \
  | grep -v '^#' | sort
```

## Данные есть, но не появились имена/расположения

Проверьте, что в `targets.yml` у устройства есть метки и файл корректный:

```bash
cat /opt/ups-monitoring-native/targets.yml
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.instance) \(.labels.ups_name // "-")"'
```

`instance` берётся из `ups_name` (если задано) — так устройство видно по имени,
а IP остаётся в метке `ups_ip`. Если имя не задано, `instance` = IP.
Файл перечитывается каждые 30 секунд, перезапуск не нужен.

## Порт занят при запуске

```bash
ss -ltnp | grep -E ':(3000|9090|9116)\b'
```

Если порт держит посторонняя программа — освободите его или смените порт в
`.env`:

```ini
GRAFANA_PORT=3001
```

При смене `SNMP_EXPORTER_PORT` ничего править не нужно: `run.sh` сам подставляет
новый порт в рабочую конфигурацию Prometheus. Достаточно
`sudo systemctl restart ups-monitoring`.

Если в логе `address already in use`, но порт свободен — значит, остался
процесс от прежнего запуска: `./stop.sh` (он найдёт процесс даже без pid-файла).
Такое бывает и после уменьшения `SNMP_SHARDS` — лишние процессы гасит
`stop.sh`, который вызывается при старте автоматически.

## Grafana не открывается

```bash
curl -s localhost:3000/api/health      # db=ok — Grafana жива
grep -i error /opt/ups-monitoring-native/data/grafana.log | tail -20
```

| Что видно | Причина | Что делать |
|---|---|---|
| `curl: connection refused` | Grafana не запущена | `sudo systemctl restart ups-monitoring`, смотреть `data/grafana.log` |
| `db=ok`, но браузер не открывает | мешает firewall | открыть порт 3000 (или `LISTEN_ADDR=127.0.0.1` + SSH-туннель) |
| `database is locked` в логе | второй процесс Grafana или жёсткое завершение | `./stop.sh`, затем запуск заново |
| страница открывается, но «No data» | Prometheus недоступен для Grafana | проверить `curl localhost:9090/-/healthy` |
| ошибки `t=… level=error msg="Failed to provision alerting"` | ошибка в правилах алертов (YAML) | проверить `grafana/provisioning/alerting/rules.yml` |

## Алерты не приходят в Telegram

```bash
sudo grep -E 'TELEGRAM' /opt/ups-monitoring-native/.env          # заполнено?
curl -s -u admin:ПАРОЛЬ localhost:3000/api/v1/provisioning/contact-points | jq .
```

Проверьте по порядку:

1. заполнены **оба** значения (`TELEGRAM_BOT_TOKEN` и `TELEGRAM_CHAT_ID`) и
   после правки был перезапуск стека;
2. в выводе `run.sh` при старте есть строка `Уведомления: Telegram включён`;
3. контакт-поинт `telegram` виден в API/интерфейсе;
4. бот добавлен в чат/канал и имеет право писать; id группы отрицательный;
5. тестовое сообщение:

   ```bash
   curl -s -u admin:ПАРОЛЬ -X POST localhost:3000/api/alert-notifications/test \
     -H 'Content-Type: application/json' -d '{"receivers":[{"name":"telegram"}]}'
   ```

Если правила сработали, а сообщения нет — проверьте состояние правил и
«Silences» (возможно, вы поставили тишину): **Grafana → Alerting**.

## Правила алертов не появились в Grafana

```bash
grep -iE 'provisioning|alerting' /opt/ups-monitoring-native/data/grafana.log | tail -20
ls /opt/ups-monitoring-native/grafana/provisioning/alerting/
```

Правила читаются при старте Grafana, поэтому после правки нужен перезапуск.
Частая причина — синтаксис YAML: проверьте файл (отступы, кавычки) и
перезапустите: `sudo systemctl restart ups-monitoring`.

## Опрос стал медленным, в логах таймауты

```bash
grep 'Error scraping' /opt/ups-monitoring-native/data/snmp_exporter.log | wc -l
curl -s 'localhost:9090/api/v1/query?query=snmp_scrape_duration_seconds' | jq -r '.data.result[] | "\(.metric.instance) \(.value[1])"'
```

* Худшее время опроса недоступного ИБП = `timeout × (retries + 1)` из `snmp.yml`
  (сейчас 2 с × 2 = 4 с). Если таймаутов много, можно уменьшить `timeout` до 1s.
* Если опрос **успешных** устройств стал долгим — устройств слишком много для
  одного `snmp_exporter` или медленная сеть, см. [scaling.md](scaling.md).

## Шардинг: шарды не распределяют или не поднимаются

Проверьте, сколько процессов реально работает и куда Prometheus шлёт запросы:

```bash
/opt/ups-monitoring-native/status.sh             # строки snmp_exporter* и «распределение»
grep -n 'генерировано' -A 12 /opt/ups-monitoring-native/data/prometheus.yml
ls /opt/ups-monitoring-native/data/snmp_exporter*.pid
```

| Что видно | Причина | Что делать |
|---|---|---|
| в `.env` стоит `SNMP_SHARDS=2`, а процесс один | не перезапустили стек | `sudo systemctl restart ups-monitoring` |
| в `data/prometheus.yml` один адрес вместо `hashmod` | в `prometheus.yml` нет маркеров блока шардинга (старый файл) | обновить `prometheus.yml` из репозитория (перезапуск установщика) |
| все ИБП на первом порту | так сработал хэш (бывает на маленьком пуле) | это нормально; при 2 шардах рост пула выровняет нагрузку |
| `snmp_exporter-1: ОСТАНОВЛЕН`, порт занят | порт `SNMP_EXPORTER_PORT+1` занят чужой программой | освободить порт или поменять `SNMP_EXPORTER_PORT` |
| в логе `SNMP_SHARDS='…' — не число, беру 1` | опечатка в `.env` | исправить значение (`1..8`) |
| часть ИБП `НЕДОСТУПЕН` после смены числа шардов | перераспределение ещё не завершилось | подождать интервал опроса; проверить `up` |

Посмотреть, какие ИБП на каком шарде:

```bash
curl -s localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | "\(.labels.instance) -> \(.scrapeUrl)"' \
  | sed 's|/snmp?.*||'
```

## Пропала история по устройству

История «рвётся», когда меняется метка `instance`. В этом проекте `instance` —
это `ups_name` из `targets.yml`, поэтому:

* смена IP при заданном `ups_name` историю **не** рвёт (адрес живёт в `ups_ip`);
* переименование `ups_name` или его удаление — рвёт (устройство выглядит новым).

Если так вышло, верните прежнее имя — данные снова склеятся.

## Растёт диск

```bash
du -sh /opt/ups-monitoring-native/data/*            # что именно растёт
du -sh /opt/ups-monitoring-native/data/prometheus
```

* растёт база Prometheus — уменьшите `RETENTION_TIME`/задайте `RETENTION_SIZE` в `.env`
  и перезапустите; см. [operations.md](operations.md#сколько-места-занимает-история);
* растут `*.log` — проверьте, работает ли logrotate:

  ```bash
  sudo logrotate -d /etc/logrotate.d/ups-monitoring
  ```

  если logrotate не установлен — поставьте его или очищайте логи вручную
  (`sudo truncate -s0 data/snmp_exporter.log`), иначе файл вырастет.

## Правка конфига не применилась

| Что правили | Когда применится |
|---|---|
| `targets.yml` | ≤30 секунд (перезапуск не нужен) |
| дашборд `grafana/dashboards/*.json` | ≤30 секунд |
| `.env`, `snmp.yml`, `prometheus.yml`, правила алертов | **после перезапуска**: `sudo systemctl restart ups-monitoring` |

`prometheus.yml` и `.env` не перечитываются автоматически — это самая частая
причина «ничего не изменилось».

## Что собрать, если нужна помощь

```bash
{
  echo "== status ==";     /opt/ups-monitoring-native/status.sh
  echo "== версии ==";     /opt/ups-monitoring-native/bin/*/prometheus --version 2>/dev/null
  echo "== ports ==";      ss -ltnp | grep -E ':(3000|9090|9116)\b'
  echo "== targets ==";    cat /opt/ups-monitoring-native/targets.yml
  echo "== логи ==";       tail -n 50 /opt/ups-monitoring-native/data/*.log
} > /tmp/ups-diag.txt 2>&1
```

Перед отправкой удалите из файла пароли и токены (`.env` в вывод не попадает).
