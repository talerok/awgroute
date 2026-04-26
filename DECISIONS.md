# DECISIONS

Лог принятых архитектурных решений. Каждая запись: дата, контекст, решение, альтернативы.

---

## 2026-04-26 — Go installed via Homebrew

**Контекст:** для сборки amnezia-box нужен Go ≥ 1.21.

**Решение:** `brew install go` → go1.26.2 darwin/arm64. Скрипт сборки ищет `go` в `PATH`, fallback на `/opt/homebrew/bin/go`.

---

## 2026-04-26 — Целевая архитектура: arm64

**Контекст:** машина разработчика — Apple Silicon. Universal Binary не делаем (PLAN.md, «Что НЕ делать»).

**Решение:** все сборки под darwin/arm64. Если понадобится Intel — пересобрать с `GOARCH=amd64`.

---

## 2026-04-26 — Backend: subprocess с sudo

**Контекст:** TUN на macOS требует root. Helper Tool / SMAppService — overkill для личного приложения.

**Решение:** GUI запускает `backend/amnezia-box` через `Process` с эскалацией через `do shell script ... with administrator privileges` (NSAppleScript). Альтернатива через NOPASSWD sudoers — оставлена как опция для пользователя.

---

## 2026-04-26 — Backend ref: тег `1.12.12-awg` (а не `awg2.0`)

**Контекст:** PLAN.md упоминает тег `awg2.0`, которого в `hoaxisr/amnezia-box` нет. Доступны ветки `main` (sync с upstream stable-next), `alpha` (dev-next) и AWG-помеченные теги `1.12.12-awg`, `1.12.12-awg-notglobal`.

**Решение:** дефолтный ref — `1.12.12-awg`. Это последняя стабильная sing-box серия (1.12.x) с явной AWG-меткой. README репозитория подтверждает поддержку «AWG 2.0 features: H1-H4 ranges, S3/S4 padding, I1-I5 obfuscation chains».

**Альтернативы:** ветка `main` — получаем обновления, но теряем воспроизводимость. Тег `1.12.12-awg-notglobal` — судя по имени, без glob-маршрутизации, нам не нужен.

**Override:** `REF=main backend/build.sh`.

---

## 2026-04-26 — Спецификация AWG endpoint в JSON-конфиге amnezia-box

**Источник:** `backend/src/option/awg.go`, `backend/src/protocol/awg/endpoint.go` (тег `1.12.12-awg`).

**Регистрация типа:** `constant.TypeAwg = "awg"` → используется в секции `endpoints[].type`.

**Полная схема endpoint:**

```jsonc
{
  "type": "awg",                       // обязательно
  "tag": "vpn",                        // строка-идентификатор для route.final / outbound

  // ── ключевое ──
  "private_key": "<base64>",           // обязательно, base64 (Curve25519, 32 байта)
  "address": ["10.8.0.2/24"],          // обязательно, список Prefix (IPv4/IPv6 локальный адрес туннеля)
  "mtu": 1408,                         // optional, default 1408
  "listen_port": 0,                    // optional, обычно 0 (любой)

  // ── AWG-специфичное (всё optional, копируется как есть из .conf) ──
  "jc": 4,                             // junk packet count, int
  "jmin": 40, "jmax": 70,              // junk size range
  "s1": 0, "s2": 0, "s3": 0, "s4": 0,  // S1-S4 size paddings (S3/S4 — AWG 2.0)
  "h1": "", "h2": "", "h3": "", "h4": "", // H1-H4 magic header values (AWG 2.0 — диапазоны/строки)
  "i1": "", "i2": "", "i3": "", "i4": "", "i5": "", // I1-I5 obfuscation chains: спецсинтаксис типа "<b 0xff><c><t><r 10>" — копировать БЕЗ парсинга

  // ── netstack vs system tun ──
  "useIntegratedTun": false,           // false → пакеты идут через gvisor netstack и попадают в sing-box TUN inbound (наш режим)
                                       // true → AWG поднимает свой системный utun (нам не нужен — sing-box уже делает TUN inbound)

  // ── peers ──
  "peers": [{
    "address": "203.0.113.10",         // host (IP или domain) сервера
    "port": 51820,                      // uint16
    "public_key": "<base64>",           // обязательно
    "preshared_key": "<base64>",        // optional. ВНИМАНИЕ: имя поля `preshared_key`, без подчёркивания между pre/shared (в legacy WG было `pre_shared_key`)
    "allowed_ips": ["0.0.0.0/0", "::/0"], // обычно catch-all для full-tunnel
    "persistent_keepalive_interval": 25  // секунды, optional
  }],

  // ── DialerOptions (наследуется) ──
  // bind_interface, routing_mark, reuse_addr, connect_timeout, tcp_fast_open, ...
  // обычно не нужны, оставляем пусто
}
```

**Маппинг .conf → JSON:**

| .conf [Interface]     | JSON endpoint            | Примечание |
|-----------------------|--------------------------|------------|
| `Address`             | `address` (Listable)     | `10.0.0.2/32` → `["10.0.0.2/32"]` |
| `PrivateKey`          | `private_key`            | base64 как есть |
| `MTU`                 | `mtu`                    | uint32 |
| `ListenPort`          | `listen_port`            | обычно отсутствует |
| `Jc/Jmin/Jmax`        | `jc/jmin/jmax`           | int |
| `S1..S4`              | `s1..s4`                 | int |
| `H1..H4`              | `h1..h4`                 | string |
| `I1..I5`              | `i1..i5`                 | string, **копировать as-is** |
| `DNS`                 | (не в endpoint!)         | в `dns.servers[]` отдельной секции |
| `Jmax`, `S2`, `H1`... | передаются в IPC-конфиг amneziawg-go (см. `genIpcConfig` в `protocol/awg/endpoint.go`) |

| .conf [Peer]          | JSON peer                | Примечание |
|-----------------------|--------------------------|------------|
| `PublicKey`           | `public_key`             | base64 |
| `PresharedKey`        | `preshared_key`          | base64 (с одним подчёркиванием!) |
| `Endpoint`            | `address`+`port`         | `host:port` → разделить |
| `AllowedIPs`          | `allowed_ips`            | comma-list → array of CIDR |
| `PersistentKeepalive` | `persistent_keepalive_interval` | seconds |

**Параметры `J1-J3` и `Itime`:** в `option/awg.go` отсутствуют (`Jmin`, `Jmax`, `Jc` есть, остальные `J*` и `Itime` — нет). Если попадутся в `.conf` — игнорировать в генераторе и логировать предупреждение.

**Важно:** AWG endpoint работает в режиме `useIntegratedTun=false` — он создаёт netstack TUN внутри себя, sing-box перехватывает системный трафик через свой `tun` inbound, route направляет в AWG, AWG шифрует и пишет в физический сокет (через `bind` к dialer). Это объясняет, почему в нашей архитектуре нужен и `tun` inbound (для всего системного трафика), и `awg` endpoint (для шифрованной отправки наружу).

---

## 2026-04-26 — Xcode-проект через `xcodegen`

**Контекст:** `.xcodeproj` — бинарный плотный формат, его неудобно править руками и держать в git.

**Решение:** проект описан в `app/project.yml` для `xcodegen`. Сгенерированный `app/AwgRoute.xcodeproj` под `.gitignore` (точнее — будет под gitignore, см. правку). Команда: `cd app && xcodegen`.

**Альтернативы:** tuist (мощнее, но overkill); чистый Swift Package executable (теряем .app bundle и Info.plist для Apple Event entitlements).

**Зависимости:** `brew install xcodegen` (уже стоит).

---

## 2026-04-26 — Эскалация привилегий: NSAppleScript «with administrator privileges» (Вариант A из PLAN.md этап 2)

**Контекст:** TUN на macOS требует root. Helper Tool / SMAppService — overkill для личного приложения.

**Решение:** `BackendController` запускает amnezia-box через `NSAppleScript` с `do shell script "..." with administrator privileges`. Особенности:
- Один запуск — один родной macOS prompt пароля.
- Авторизация кэшируется ~5 минут на одном AppleScript-сеансе.
- `nohup ... &` + redirect в файл + `echo $! > /tmp/awgroute-amnezia-box.pid` — backend живёт независимо от AppleScript-вызова.
- Stop через тот же механизм: `kill -TERM` → ждать 5 сек → `kill -KILL`.

**Альтернатива** (Вариант B): NOPASSWD sudoers. Оставлено пользователю — задокументирую в README.

**Stop при выходе GUI:** синхронный `NSAppleScript` в `applicationWillTerminate` (вне async runtime). Cached auth обычно срабатывает без prompt'а.

---

## 2026-04-26 — Подцепление к работающему backend при рестарте GUI (сверх PLAN.md)

**Контекст:** PLAN требует «cleanup при выходе GUI». Но обратный сценарий — GUI крашнулся / закрылся, backend остался жить — тоже встречается.

**Решение:** при инициализации `BackendController` читает `/tmp/awgroute-amnezia-box.pid` и проверяет процесс через `kill(pid, 0)`. Если жив — статус сразу `.running(pid:)`. Это позволяет рестартовать GUI без потери туннеля и не требует ничего от пользователя.

---

## 2026-04-26 — Scope правил роутинга: глобальный

**Контекст:** PLAN.md этап 4 предлагает выбрать scope правил.

**Решение:** один общий `rules.json` (`~/Library/Application Support/AwgRoute/rules.json`) для всех профилей.

**Why:** правила меняются редко, профили часто. Общий scope упрощает UI (одна вкладка вместо вкладки внутри профиля), позволяет переключать сервер без переписывания правил.

---

## 2026-04-26 — Формат `rules.json`: Вариант A (только секция `route`)

**Контекст:** PLAN.md этап 4 даёт выбор между Variant A (только `route`) и Variant B (`route` + опционально `dns`).

**Решение:** Вариант A. JSON верхнего уровня — это то, что попадёт в секцию `route` итогового конфига.

**Why:** меньше boilerplate в шаблонах, проще писать правила, не надо понимать структуру `dns`. DNS остаётся захардкоженной частью генератора (см. `AwgJSONGenerator.defaultDNSDict`).

---

## 2026-04-26 — В правилах НЕТ поля `comment`

**Контекст:** sing-box строго парсит правила и отвергает unknown fields. `{ "comment": "..." }` ломает конфиг.

**Решение:** в шаблонах правил `comment`-полей нет. Описания правил даются в README, не в самом JSON. Это касается и пользовательского `rules.json` — генератор не экранирует и не вырезает `comment`, просто пробрасывает в sing-box, который ругается.

**Альтернативы:** JSON5 / JSONC — JSONSerialization их не поддерживает; добавлять зависимость нет смысла.

---

<!-- Добавлять новые записи сверху, под этой строкой -->
