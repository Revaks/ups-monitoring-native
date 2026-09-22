# Установка, обновление, удаление

## Содержание

* [Быстрая установка](#быстрая-установка)
* [Что делает установщик](#что-делает-установщик)
* [Все ключи установщика](#все-ключи-установщика)
* [Проверка после установки](#проверка-после-установки)
* [Установка без интернета и без установщика](#установка-без-интернета-и-без-установщика)
* [systemd: как это работает](#systemd-как-это-работает)
* [Обновление](#обновление)
* [Удаление](#удаление)
* [ARM и другие архитектуры](#arm-и-другие-архитектуры)

## Быстрая установка

Одна команда (нужен root и интернет):

```bash
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh | sudo bash
```

Установщик спросит:

1. список ИБП — можно вводить строками `<IP> [имя] [расположение]`, пустая строка завершает ввод;
2. SNMP community (по умолчанию `public`);
3. логин и пароль администратора Grafana (пароль можно оставить предложенный).

Без вопросов — всё параметрами:

```bash
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh \
  | sudo bash -s -- --yes \
      --targets '192.168.1.10:UPS-01:Коммутационный узел №1,192.168.1.11:UPS-02' \
      --community 'public' \
      --password 'Str0ng-Pass'
```

Если список ИБП ещё не готов — установите без него (`--yes` без `--targets`),
потом допишите `targets.yml`: это обычный текстовый файл, см.
[configuration.md](configuration.md).

## Что делает установщик

| Шаг | Что происходит |
|---|---|
| Проверки | root, наличие `curl`/`tar`/`sed`/`awk`, архитектура, наличие systemd |
| Остановка старой версии | `systemctl stop ups-monitoring` и `stop.sh`, если стек уже стоял |
| Файлы | распаковывает репозиторий в `/opt/ups-monitoring-native`, копирует `docs/` |
| Настройка | правит `community` в `snmp.yml`, пишет `targets.yml` и `.env` (права `600`) |
| Бинарники | качает snmp_exporter, Prometheus, Grafana и **проверяет sha256**, раскладывает в `bin/` |
| Порти | предупреждает, если 3000/9090/9116 заняты |
| systemd | ставит юнит `ups-monitoring.service` и включает автозапуск |
| Логи | создаёт правило ротации `/etc/logrotate.d/ups-monitoring` |
| Запуск | `systemctl restart ups-monitoring` и ожидание ответа сервисов |
| Проверка | опрашивает первый ИБП по SNMP и показывает, что получилось |

Повторный запуск установщика — это же и обновление: `.env` и `targets.yml`
сохраняются, недостающие ключи в `.env` дописываются.

## Все ключи установщика

```bash
sudo ./install.sh --help
```

| Ключ | Значение |
|---|---|
| `-d, --dir PATH` | каталог установки (по умолчанию `/opt/ups-monitoring-native`) |
| `-r, --ref REF` | ветка или тег репозитория (по умолчанию `main`) |
| `-t, --targets SPEC` | список ИБП: `IP[:ИМЯ[:РАСПОЛОЖЕНИЕ]]` через запятую |
| `-c, --community STR` | SNMP community (по умолчанию `public`) |
| `-u, --user NAME` | логин администратора Grafana (по умолчанию `admin`) |
| `-p, --password PASS` | пароль Grafana (если не задан — сгенерируется) |
| `--telegram-token T` | токен бота Telegram для уведомлений |
| `--telegram-chat ID` | id чата/канала для уведомлений |
| `-y, --yes` | не задавать вопросов, использовать значения по умолчанию |
| `--systemd` / `--no-systemd` | поставить или не ставить systemd-юнит |
| `--no-download` | не скачивать бинарники (их скачает `run.sh` при запуске) |
| `--no-start` | только разложить файлы и настройки, не запускать |
| `--uninstall` | удалить юнит и остановить стек (`--purge` — вместе с каталогом и данными) |

## Проверка после установки

```bash
/opt/ups-monitoring-native/status.sh
```

Скрипт покажет: запущены ли сервисы, отвечают ли они по HTTP, сколько ИБП в
списке, сколько правил алертов, включены ли уведомления и сколько хранится
история. Ожидаемый вывод:

```
  snmp_exporter  запущен (pid 1234) порт 9116  отвечает
  prometheus     запущен (pid 1235) порт 9090  отвечает
  grafana        запущен (pid 1236) порт 3000  отвечает
```

Дальше:

* Grafana → `http://<IP-сервера>:3000`, дашборд **«ИБП — обзор»**;
* если ИБП показан как `НЕДОСТУПЕН` — см. [troubleshooting.md](troubleshooting.md).

## Установка без интернета и без установщика

Установщик удобен, но не обязателен: `run.sh` сам скачивает бинарники при
первом запуске (тогда проверки sha256 не будет — качайте бинарники заранее,
если это важно).

```bash
git clone https://github.com/Revaks/ups-monitoring-native.git
cd ups-monitoring-native
cp .env.example .env 2>/dev/null || true   # при необходимости
vi targets.yml                             # впишите свои ИБП
./run.sh                                   # скачает бинарники и запустит стек
./status.sh
```

Sudo не нужен, если каталог ваш и порты 3000/9090/9116 свободны. Остановить:
`./stop.sh`.

## systemd: как это работает

Юнит `ups-monitoring.service` запускает `run.sh --foreground` — это супервизор:

* держит три процесса дочерними и **перезапускает упавший** через 5 секунд;
* по `systemctl stop` получает сигнал и аккуратно останавливает сервисы;
* если сам супервизор упадёт, systemd поднимет его (`Restart=on-failure`),
  но не более 3 раз за 5 минут (`StartLimitBurst`), чтобы не зацикливаться.

```bash
sudo systemctl status ups-monitoring        # состояние
sudo systemctl restart ups-monitoring       # применить изменения конфигов
sudo systemctl stop ups-monitoring
journalctl -u ups-monitoring -n 50          # сообщения супервизора
```

Логи сервисов — не в journal, а в файлы `data/*.log` (их ротирует logrotate
раз в неделю, хранится 8 архивов).

## Обновление

```bash
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh \
  | sudo bash -s -- --yes
```

Что сохраняется: `.env` (логин/пароль Grafana, токен Telegram), `targets.yml`,
каталог `data/` (история Prometheus и база Grafana). Что обновляется: скрипты,
конфиги, дашборд, правила алертов, `docs/`.

Важно: установщик перезаписывает `run.sh` из репозитория. Если вы правили
`run.sh` на сервере (например, добавляли `--web.listen-address`), перенесите
правку в репозиторий — иначе она потеряется при обновлении.

## Удаление

```bash
# остановить и удалить юнит, файлы и настройки оставить
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh \
  | sudo bash -s -- --uninstall

# то же, но вместе с каталогом и всей историей
curl -fsSL https://raw.githubusercontent.com/Revaks/ups-monitoring-native/main/install.sh \
  | sudo bash -s -- --uninstall --purge
```

Удаляются: systemd-юнит, правило logrotate, процессы. Остаются (без `--purge`):
`/opt/ups-monitoring-native` целиком — можно поставить заново и продолжить с той
же историей.

## ARM и другие архитектуры

Установщик определяет архитектуру сам: `amd64`, `arm64`, `armv7`, `armv6`.
Для Raspberry Pi и подобных достаточно той же команды — версии бинарников
подберутся под платформу.

Если ставите вручную (без установщика), поправьте в `run.sh` строку
`ARCH="linux-amd64"` на нужную: `linux-arm64`, `linux-armv7` или `linux-armv6`.
