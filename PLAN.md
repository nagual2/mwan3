# mwan3 — план задач

Обновлён: 2026-09-25

## Активное: фикс «интернет не отключается, пока доступен последний канал»

Проблема: при провале track-пингов mwan3 помечает интерфейс offline; если offline уходят все каналы политики, терминальное правило политики ставит метку `unreachable` (`ip rule` → EHOSTUNREACH) — трафик политики убивается, даже если линк физически жив. Кейс prod wwan: отельный апстрим роняет ICMP окнами по 15–60 с каждые 2–4 мин при стабильной WiFi-ассоциации (диагностика 2026-09-25, см. EchoVault `prod wwan флапает`).

Текущее состояние прода (проверено живыми окнами 2026-09-25 19:11–19:20 UTC):

| # | Факт | Источник |
|---|------|----------|
| 1 | Workaround Пилота: `default_rule_v4 → use_policy 'default'` — интернет LAN при offline последнего канала жив | конфиг `/etc/config/mwan3` |
| 2 | Цена: политика `ipv4_primary` без ссылок (0 references), mwan3 де-факто monitor-only, policy-switching мёртв | `iptables -t mangle -L mwan3_policy_ipv4_primary` |
| 3 | Рубильник жив, но не дотягивается: при offline policy-цепочка получает терминальный `MARK xset 0x3e00` (unreachable); правило `2001` (fwmark 0x100 → table 1) и table 1 при этом НЕ удаляются | дампы во всех состояниях mwan3track |
| 4 | IPv6 НЕ защищён: `default_rule_v6 → ipv6_primary` (tb64, `last_resort unreachable`) — при offline tb64 v6-трафик будет убит | конфиг |
| 5 | LAN-транзит и DNS через роутер в offline-окнах: 0 unreachable-отказов, только таймауты реальных потерь | наблюдатели minisforum |

### 1. Конфиг-фикс на prod (рекомендуемое, без правок кода)

Механика: `files/lib/mwan3/mwan3.sh:683–743` — `mwan3_create_policies_iptables`, `config_get last_resort … unreachable` (дефолт), case :705: `default` → `-j MARK --set-xmark $MMX_DEFAULT` («handled», трафик → main-таблица), `*` → `$MMX_UNREACHABLE` (kill). Опция нативная, upstream-код не трогается.

| # | Шаг | Команда / действие |
|---|-----|---------------------|
| 1 | Бэкап | `uci export mwan3 > /root/backup-mwan3-lastresort-$(date +%Y%m%d-%H%M%S).uci` |
| 2 | A1 (минимальный) | `uci set mwan3.ipv4_primary.last_resort='default'`; `uci set mwan3.ipv6_primary.last_resort='default'` |
| 3 | A2 (полный возврат в mwan3, опция поверх A1) | `uci set mwan3.default_rule_v4.use_policy='ipv4_primary'` — LAN снова маркируется и ходит через политики; при offline последнего канала терминальный default-MARK уводит трафик в main-таблицу |
| 4 | Применить | `uci commit mwan3 && service mwan3 reload` |
| 5 | Контроль туннелей | `mwan3 status` (tb62–tb64/tb6 online), ping через туннели |

Выбор A1/A2 — за Пилотом: A1 = нулевой риск, семантика чинится «на будущее»; A2 = восстанавливает маршрутизацию mwan3 (нужно при появлении второго v4-канала), требует полного цикла верификации.

### 2. Регрессионный тест в форке (TDD-гард)

| # | Элемент | Содержание |
|---|---------|------------|
| 1 | Файл | `tests/test_last_resort_default.sh` (подхватится `tests/run_tests.sh` по маске `test_*.sh`) |
| 2 | Кейс 1 — upstream-поведение | policy без `last_resort` → терминальное правило `--comment "unreachable"` (фиксирует дефолт) |
| 3 | Кейс 2 — гард фикса | policy с `last_resort='default'` → терминальное `--comment "default" -j MARK --set-xmark $MMX_DEFAULT`, правила unreachable нет |
| 4 | Инфраструктура | моки `tests/mocks/bin` (iptables, ip, uci); запуск `wsl bash tests/run_tests.sh` из корня проекта |
| 5 | Порядок | тест пишется и зелёный ДО правки прода (код уже поддерживает `default`); правка прода не должна тест сломать |

### 3. Верификация на prod (после правки)

Наблюдатели ≥30 мин (≥5 offline-окон): роутер — `mwan3 status` + дамп policy-цепочки на переходах + `ip rule`/`table 1`; minisforum — `curl -4 https://1.1.1.1` и `dig @192.168.35.1` каждые 3 с.

### Критерии приёмки

| # | Критерий |
|---|----------|
| 1 | При offline всех каналов политики интернет LAN жив (транзит + DNS); отказы только таймаутами реальных потерь, ни одного мгновенного unreachable |
| 2 | Policy-цепочка в offline содержит терминальный default-MARK, unreachable отсутствует |
| 3 | Тест форка зелёный: `wsl bash tests/run_tests.sh` |
| 4 | Monitoring не деградировал: статус wwan в LuCI/mwan3 по-прежнему отражает offline/online |
| 5 | (A2) При появлении второго v4-канала failover по метрикам работает |

### Rollback

`uci import mwan3 < /root/backup-mwan3-lastresort-*.uci && service mwan3 restart`; для A2 — дополнительно вернуть `default_rule_v4.use_policy='default'`.

### Риски и ограничения

| # | Риск | Обработка |
|---|------|-----------|
| 1 | `last_resort='default'` при offline всех каналов: если физический линк тоже мёртв — «тихие» таймауты вместо мгновенного unreachable | Осознанный trade-off; для диагностики статус mwan3 остаётся |
| 2 | A2 меняет маркировку LAN (conntrack 0x100) на живом проде | Применять в окно низкой нагрузки; `reload`, не `restart`; контроль туннелей после |
| 3 | IPv6: default-MARK помогает, только пока netifd держит v6-дефолт в main (интерфейс up, но track красный) | При полном ifdown tb64 v6 умрёт честно — это не флап, а реальный down |
| 4 | Тест-гард — кандидат в upstream PR | Отдельное решение Пилота, в скоуп фикса не входит |

## Принципы ведения

- Прод не менять без явной команды Пилота; каждая правка = бэкап + верификация по §3.
- Значимые решения и результаты сессий — `memory_save` (EchoVault, проект `openwrt-prod`).
