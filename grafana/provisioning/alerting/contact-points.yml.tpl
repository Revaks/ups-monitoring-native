# Сгенерировано run.sh из contact-points.yml.tpl — не редактируйте этот файл,
# он перезаписывается при каждом запуске. Настраивается через .env:
#   TELEGRAM_BOT_TOKEN — токен бота, получить у @BotFather
#   TELEGRAM_CHAT_ID   — id чата (для группы/канала — отрицательное число)
# =====================================================================
#  Контакт-поинт для уведомлений (Grafana unified alerting)
# =====================================================================
#  Файл создаётся, только если в .env заданы TELEGRAM_BOT_TOKEN и
#  TELEGRAM_CHAT_ID. По умолчанию уведомления выключены: правила алертов
#  считаются и видны в Grafana -> Alerting -> Alert rules, но никуда не
#  отправляются (никакого Telegram-контакт-поинта не создаётся).
#
#  Почему подстановка текстом, а не ${TELEGRAM_CHAT_ID} средствами Grafana:
#  Grafana приводит интерполированное значение к типу по содержимому, и
#  числовой id чата (например -1001234567890) становится числом — Grafana
#  не запускается с ошибкой «cannot unmarshal number into Go struct field
#  Config.chatid of type string». Кавычки и тег !!str в YAML не помогают,
#  а литеральная строка в кавычках работает (проверено на Grafana 11.5.1).
# =====================================================================

apiVersion: 1

contactPoints:
  - orgId: 1
    name: telegram
    receivers:
      - uid: ups_telegram
        type: telegram
        settings:
          bottoken: "@@TELEGRAM_BOT_TOKEN@@"
          chatid: "@@TELEGRAM_CHAT_ID@@"
        disableResolveMessage: false
