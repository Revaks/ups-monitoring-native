# Безопасность и доступ

## Содержание

* [Что и где слушает](#что-и-где-слушает)
* [Закрыть лишние порты](#закрыть-лишние-порты)
* [Доступ к Grafana](#доступ-к-grafana)
* [Секреты: пароли, токены, community](#секреты-пароли-токены-community)
* [Откуда берутся бинарники](#откуда-берутся-бинарники)
* [Итоговый чек-лист](#итоговый-чек-лист)

## Что и где слушает

| Сервис | Порт | Зачем нужен снаружи |
|---|---|---|
| Grafana | 3000 | да, если вы смотрите дашборд не с сервера |
| Prometheus | 9090 | нет — это внутренний сервис (интерфейс нужен только для отладки) |
| snmp_exporter | 9116 | **нет, никогда** — см. ниже |

Порт 9116 — это SNMP-прокси: запрос вида
`http://сервер:9116/snmp?target=10.0.0.1&module=ups` заставляет сервер мониторинга
сам отправить SNMP-запрос на указанный адрес. Если порт открыт в сеть, любой,
кто до него дотянется, сможет опрашивать **произвольные адреса вашей внутренней
сети** от имени сервера мониторинга (и нагружать сеть). Поэтому его закрывают.

По умолчанию (как ставит `install.sh`) все три сервиса слушают все интерфейсы —
это удобно для быстрого старта. Ниже — как это ужать.

## Закрыть лишние порты

### Способ 1: привязать к localhost (правильный)

В `.env`:

```ini
LISTEN_ADDR=127.0.0.1
```

и перезапустить стек:

```bash
sudo systemctl restart ups-monitoring
```

Что станет: `snmp_exporter` и `Prometheus` будут доступны только с самого
сервера, Grafana — тоже. Дашборд открывайте через SSH-туннель:

```bash
ssh -L 3000:127.0.0.1:3000 user@ups-host     # затем http://localhost:3000
```

Если Grafana нужна по сети, оставьте для неё доступ через firewall (или
поставьте reverse proxy с TLS), а 9090/9116 закройте.

Проверка:

```bash
ss -ltnp | grep -E ':(3000|9090|9116)\b'
```

Ожидаемо: у 9090 и 9116 адрес `127.0.0.1`, а не `0.0.0.0`.

### Способ 2: firewall

```bash
# ufw
sudo ufw deny 9090/tcp
sudo ufw deny 9116/tcp          # и 9117, 9118… если включён шардинг (SNMP_SHARDS)
sudo ufw allow from 10.0.0.0/24 to any port 3000 proto tcp   # Grafana — только своей сети

# firewalld
sudo firewall-cmd --permanent --remove-port=9090/tcp --remove-port=9116/tcp
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.0.0.0/24 port port=3000 protocol=tcp accept'
sudo firewall-cmd --reload
```

### Способ 3: Grafana за reverse proxy с TLS

Если дашборд должен быть доступен из интернета, ставьте перед Grafana nginx:

```nginx
location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

и укажите Grafana, что она за прокси (в `.env`):

```ini
GF_SERVER_ROOT_URL=https://ups.example.com/
```

## Доступ к Grafana

* Пароль администратора задаётся при установке (`--password`) или в `.env`
  (`GRAFANA_ADMIN_PASSWORD`), файл `.env` доступен только root (`600`).
* Регистрация новых пользователей отключена (`GF_USERS_ALLOW_SIGN_UP=false`).
* Анонимный доступ выключен — Grafana всегда требует логин.
* Не заводите один общий пароль на всех: в Grafana удобнее создать отдельного
  пользователя с ролью `Viewer` для дежурных, а `Admin` оставить себе
  (**Administration → Users**).

## Секреты: пароли, токены, community

| Что | Где лежит | Как защитить |
|---|---|---|
| Пароль Grafana | `.env` | `chmod 600 .env`, не попадает в git |
| Токен Telegram | `.env` | то же |
| SNMP community | `snmp.yml` | `chmod 600 snmp.yml`, лучше — SNMP v3 (см. ниже) |
| Пароли SNMP v3 | лучше в `.env` | `password: ${SNMP_V3_PASSWORD}` в `snmp.yml` |

Подстановка переменных окружения в `snmp.yml` работает всегда: `run.sh` запускает
экспортёр с `--config.expand-environment-variables`, а переменные берёт из `.env`.
Так пароли не попадают в конфиг:

```ini
# .env
SNMP_V3_PASSWORD=Str0ng-Auth-Pass
SNMP_V3_PRIV_PASSWORD=Str0ng-Priv-Pass
```

```yaml
# snmp.yml
  dc_v3:
    version: 3
    security_level: authPriv
    username: upsmon
    password: ${SNMP_V3_PASSWORD}
    priv_password: ${SNMP_V3_PRIV_PASSWORD}
    auth_protocol: SHA
    priv_protocol: AES
```

Про SNMP как таковой:

* **community — это пароль в открытом виде** (SNMP v1/v2c не шифрует). Ставьте
  не `public`, а своё значение, и ограничьте на ИБП список адресов, которым
  разрешён SNMP (ACL) — тогда доступ будет только у сервера мониторинга;
* если ИБП умеет **SNMP v3** (`authPriv`) — используйте его: и аутентификация,
  и шифрование. Пример блока — выше и в `snmp.yml`;
* разные устройства могут использовать разные учётки: имя блока указывается в
  метке `snmp_auth` в `targets.yml`, см. [configuration.md](configuration.md).

Проверить права на файлы:

```bash
ls -l /opt/ups-monitoring-native/.env /opt/ups-monitoring-native/snmp.yml
```

## Откуда берутся бинарники

| Компонент | Источник |
|---|---|
| snmp_exporter | `github.com/prometheus/snmp_exporter` (GitHub Releases) |
| Prometheus | `github.com/prometheus/prometheus` (GitHub Releases) |
| Grafana | `dl.grafana.com/oss/release` |

Установщик проверяет sha256 скачанных архивов. `run.sh` при самостоятельной
загрузке проверяет только доступность файла — если это важно, скачивайте
бинарники установщиком (`install.sh` без `--no-download`).

Скачиваются фиксированные версии (см. `SNMP_VER`, `PROM_VER`, `GF_VER` в
`run.sh`), внезапных обновлений «из-под ног» не бывает.

## Итоговый чек-лист

- [ ] `LISTEN_ADDR=127.0.0.1` (или firewall: 9090/9116 закрыты, 3000 — по подсети)
- [ ] пароль Grafana не `admin`, вход по сети ограничен
- [ ] `chmod 600 .env` и `chmod 600 snmp.yml`
- [ ] community не `public`, на ИБП включён ACL для сервера мониторинга
- [ ] пароли/токены не попали в git (`git status` чистый, `.env` в `.gitignore`)
- [ ] проверить: `ss -ltnp | grep -E ':(9090|9116)\b'` — только `127.0.0.1`
- [ ] настроена внешняя проверка доступности мониторинга
      (см. [operations.md](operations.md#следить-за-самим-мониторингом))
