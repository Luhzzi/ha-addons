# Aurum add-on для Home Assistant

[Aurum](https://github.com/Zproger/Aurum) — self-hosted «финансовая ОС»: денежные
потоки, чистое состояние, бюджеты и все ваши источники дохода в одном месте.
Оригинальный проект запускается тремя Docker-контейнерами (Postgres + FastAPI +
nginx) через Docker Compose. Этот аддон упаковывает все три роли **в один
контейнер**, так что Aurum ставится как обычный аддон Home Assistant на
`aarch64` (Raspberry Pi 4/5) и `amd64`.

Данные Postgres хранятся в персистентном `/data` аддона и переживают рестарты,
переустановки и обновления.

## Состав

```
aurum/
├── config.yaml       # опции аддона (UI в Home Assistant), порт 8099
├── Dockerfile        # сборка из исходников Aurum (main) в 3 стадии
├── run.sh            # initdb → миграции → uvicorn → nginx
├── nginx.conf        # конфиг nginx из upstream, backend на 127.0.0.1:8000
├── 20-basic-auth.sh  # без изменений из upstream (httpid + Basic Auth)
├── 25-allowed-hosts.sh # без изменений из upstream (защита от DNS rebinding)
└── translations/     # подписи опций в интерфейсе HA
```

## Как поставить

Этот аддон раздаётся через **готовые образы в GHCR** (сборка на GitHub Actions),
поэтому Home Assistant ничего не собирает сам — только скачивает готовый образ.

1. Скопируйте файлы этого репозитория, если форкаете — образ уже публикуется под `ghcr.io/luhzzi` только при сборке в этом репозитории. Для своего репозитория также замените поле `image` в `aurum/config.yaml` (только строчными буквами, иначе сборка упадёт):

   ```yaml
   image: "ghcr.io/ВАШ_USERNAME/aurum-addon"
   ```

2. Запушьте в ветку `main`. Workflow `.github/workflows/builder.yaml` соберёт
   образы для `aarch64` и `amd64` и опубликует их в GHCR вашего аккаунта.
3. В Home Assistant: **Настройки → Аддоны → меню (⋮) → Репозитории** →
   вставьте URL вашего репозитория → **Добавить**.
4. В магазине аддонов появится **Aurum** → **Установить**.
5. Настройте опции (см. ниже) → **Запустить**.
6. Откройте `http://IP_вашего_HA:8099` или кнопку **«Открыть веб-интерфейс»**.

> Первый вход настраивать не нужно: учётная запись и стандартные категории
> создаются автоматически.

## Конфигурация

| Опция | По умолчанию | Что делает |
| --- | --- | --- |
| `postgres_password` | пусто | Пароль внутреннего Postgres. Пусто → сгенерируется при первом старте и сохранится в `/data` |
| `postgres_db` | `aurum` | Имя базы данных |
| `default_currency` | `USD` | Валюта по умолчанию (USD/EUR/RUB/…) |
| `coingecko_api_key` | пусто | Бесплатный Demo-ключ для цен крипты (coingecko.com/en/api/pricing) |
| `enable_docs` | `true` | Swagger/ReDoc на `/api/docs` |
| `basic_auth_user` / `basic_auth_password` | пусто | HTTP Basic Auth перед всем приложением |
| `allowed_hosts` | `*` | Разрешённые Host-заголовки; `*` отключает проверку (работа по IP) |

**Обязательно задайте `basic_auth_user` и `basic_auth_password`** — порт
публикуется в вашу локальную сеть, а у Aurum нет собственного входа. Без Basic
Auth любой в вашей сети сможет читать и менять ваши финансовые данные.

## Обновление

Публикации записываются в GHCR тегом `latest` и тегом версии. Чтобы выпустить
новую версию: поднимите `version` в `aurum/config.yaml`, закоммитьте и запушьте в
`main`. В Home Assistant нажмите «Проверить обновления» на странице аддона.

Чтобы привязаться к конкретной версии исходников Aurum (а не к `main`), задайте
`ARG AURUM_REF` в `aurum/Dockerfile` (имя тега или SHA коммита) и пересоберите.

## Безопасность

- Приложение не опубликовано в интернет намеренно: доступ по `http://<IP>:8099`
  внутри вашей сети, Basic Auth закрывает само приложение.
- Включите HTTPS на уровне Home Assistant (например через Nginx Proxy Manager
  или облачный туннель) перед тем, как открывать порт наружу — иначе пароль
  Basic Auth ходит в открытом виде.
- У аддона нет `hassio_api`/`homeassistant_api`/`privileged` — единственный
  открытый наружу ресурс — это порт 8099.

# Firefly III add-on для Home Assistant

[Firefly III](https://github.com/firefly-iii/firefly-iii) — open source
персональный финансовый менеджер: бюджеты, счета, регулярные транзакции,
мультивалютность. Аддон упаковывает Firefly III **и его базу MariaDB в один
контейнер** на основе официального образа `fireflyiii/core` (порт 8098).

```
firefly-iii/
├── config.yaml  # опции аддона, порт 8098 (внутри контейнера nginx на 8080)
├── Dockerfile   # официальный fireflyiii/core + MariaDB
└── run.sh       # MariaDB → схема БД (автоматически) → официальный entrypoint
```

Схема БД и миграции создаются самим официальным образом при первом старте.
Установка — как у Aurum (шаги 3–6 выше): добавьте репозиторий в HA → установите
**Firefly III** → откройте `http://IP_вашего_HA:8098` → зарегистрируйте первого
пользователя. Данные — БД, загрузки и сгенерированные ключи — хранятся в
`/data` и переживают рестарты и обновления.

## Локальная разработка

Сборка и прогон локально (только для отладки, Home Assistant это не нужно):

```bash
docker build --build-arg BUILD_VERSION=0.1.0 -t aurum-addon:test ./aurum

mkdir -p /tmp/aurum-data
# /data/options.json в проде создаёт Supervisor; для теста кладём файл сами
echo '{"postgres_password":"test","default_currency":"USD"}' > /tmp/aurum-data/options.json

docker run --rm -it -p 9000:8099 -v /tmp/aurum-data:/data aurum-addon:test
# откройте http://localhost:9000 (или /api/health) для проверки
```