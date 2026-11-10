# vless-router-panel

Панель **«VLESS на роутере»** для OpenWrt / GL.iNet: веб-страница на `http://192.168.8.1:8088` для включения и выключения прозрачного прокси, теста подключения и скорости, сохранения ссылок `vless://`, `hysteria2://`, `naive+https://` и конфига WireGuard (`.conf`), и автообновления этих конфигов по ссылке подключения каждого протокола.

Это пакет **`.ipk`** для `opkg`, не `.deb`. На OpenWrt (в том числе GL.iNet GL-BE6500, OpenWrt 23.05, `aarch64_cortex-a53`) пакеты ставятся через `opkg`. Архитектура пакета — `all`: внутри только скрипты. Бинарь `naive` (~13 МБ) в пакет **не входит** — его ставит скрипт `install-naive.sh`.

---

A small OpenWrt web panel for toggling a transparent VLESS / Hysteria2 / Naive / WireGuard proxy, testing the connection and speed, and saving protocol links or a WireGuard `.conf`. Ships as an `.ipk` (`Architecture: all`) and an unsigned `opkg` feed. The `naive` binary is not bundled; see `install-naive.sh`. No user secrets are included in the package or this repository.

## Установка на GL.iNet GL-BE6500

1. Подключитесь к роутеру.

   ```sh
   ssh root@192.168.8.1
   ```

2. Обновите список пакетов, скачайте пакет и поставьте его (opkg на GL.iNet не принимает ссылку напрямую, поэтому сначала `wget`):

   ```sh
   opkg update
   cd /tmp && wget -O vrp.ipk https://raw.githubusercontent.com/Xstrwe/Aurora-router-panel/main/feed/all/vless-router-panel_1.3.0_all.ipk && opkg install /tmp/vrp.ipk; rm -f /tmp/vrp.ipk
   ```

3. Откройте в браузере `http://192.168.8.1:8088`. Если установщик написал предупреждение про пароль, значит вход на страницу ещё не настроен — см. раздел [Auth / Пароль на страницу](#auth--пароль-на-страницу).

4. Вставьте ссылку в поле и нажмите подключить.

5. Новая версия ставится той же командой, только с новой ссылкой на `.ipk` (смотрите номер версии в имени файла). Ваши ссылки и настройки при обновлении сохраняются.

6. Удалить пакет:

   ```sh
   opkg remove Aurora-router-panel
   ```

Если LAN-адрес роутера не `192.168.8.1`, поправьте `uhttpd.vless.listen_http` через `Luci` и перезапустите `uhttpd`.

Для Hysteria2, Naive и WireGuard сначала сохраните обычную ссылку `vless://` (по ней собирается базовый конфиг Xray), а уже потом нажимайте кнопку нужного протокола.

### Naive

Бинарный файл `naive` в пакет не входит. На GL-BE6500 нужна статическая сборка `openwrt-aarch64_cortex-a53-static` с [релизов klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy/releases). На роутере:

```sh
opkg update && opkg install xz
/usr/libexec/vless-panel/install-naive.sh
```

Скрипт сам определит архитектуру, скачает последний релиз и положит бинарь в `/usr/bin/naive`. Уже существующий `/etc/naive/config.json` он не трогает. Если GitHub с роутера недоступен, скачайте архив на компьютере и укажите URL или скопируйте бинарь вручную:

```sh
/usr/libexec/vless-panel/install-naive.sh https://github.com/klzgrad/naiveproxy/releases/download/v154.0.8037.49-5/naiveproxy-v154.0.8037.49-5-openwrt-aarch64_cortex-a53-static.tar.xz
# или:
# scp naive root@192.168.8.1:/usr/bin/naive
# ssh root@192.168.8.1 chmod 755 /usr/bin/naive
```

Переустановка: `/usr/libexec/vless-panel/install-naive.sh --force`. После этого вставьте ссылку `naive+https://` на странице и нажмите **«Подключить Naive»**.

### WireGuard

Вставьте в поле целиком свой `.conf` (блоки `[Interface]` с `PrivateKey` и `Address` и `[Peer]` с `PublicKey`, `Endpoint` и `AllowedIPs`) и нажмите **«Подключить WireGuard»**. Туннель поднимается через встроенный outbound WireGuard в Xray, отдельный `wireguard-tools` не требуется. Обычный WireGuard в некоторых сетях могут блокировать — если не заработает, нажмите **«Подключить VLESS»**.

Список изменений по версиям: [CHANGELOG.md](CHANGELOG.md).

## Автообновление конфигов

Под каждым протоколом на странице (VLESS, Hysteria2, Naive, WireGuard) есть блок **«Автообновление»**:

- поле для ссылки на обновление (подписка или прямая ссылка на конфиг этого протокола);
- галочка вкл/выкл, интервал (1 час / 6 часов / 24 часа);
- кнопки **«Сохранить»** и **«Обновить сейчас»**.

Карточки протоколов на странице идут сеткой в два столбца (на узком экране — в один), в каждой: поле ссылки, кнопка **«Подключить …»**, блок автообновления.

Настройки хранятся в `/etc/xray/autoupdate/<протокол>.conf` и при обновлении пакета не затираются.

Откуда берётся свежий конфиг: из ссылки, указанной в поле «Автообновление» под этим протоколом. Если поле пустое, берётся уже сохранённая ссылка подключения этого протокола — но только если это `http(s)`-подписка; обычная ссылка `vless://`, `hysteria2://`, `naive+https://` или конфиг WireGuard повторно скачать нельзя, тогда обновлять нечего (будет сообщение «нечего обновлять»). Отдельного сервера обновлений нет. Старые настройки с `source=` в `/etc/xray/autoupdate/*.conf` просто игнорируются.

По расписанию раз в час cron запускает `/usr/libexec/vless-panel/autoupdate-run.sh`: если у протокола включено автообновление и прошёл выбранный интервал, скрипт скачивает ссылку (с таймаутом и ограничением размера). Подойдёт и обычная ссылка/конфиг, и подписка в base64 — берётся первая запись нужного протокола. Если содержимое не изменилось, файлы не трогаются. Если изменилось:

- для **текущего** протокола конфиг применяется сразу (через тот же путь, что и кнопки «Подключить …»);
- для остальных только сохраняется файл, протокол сам не переключается.

Если после применения активного протокола Xray не запустился или проверка `curl` через SOCKS `127.0.0.1:10808` на `https://www.google.com/generate_204` не прошла, всё откатывается к предыдущим файлам и службы перезапускаются — роутер не должен остаться без интернета. Прозрачный режим при этом сохраняется как был (если не было файла `/etc/xray/tproxy.disabled`, tproxy остаётся включённым).

Строка cron добавляется и убирается пакетом сама, повторная установка её не дублирует. Сами расписания и ссылки пакет не включает: по умолчанию автообновление выключено, пока вы его не сохраните на странице.

## Requirements / Требования


Ставятся из обычных фидов OpenWrt (зависимости пакета):

- `curl`, `jq`, `ucode`, `uhttpd`, `kmod-nft-tproxy`
- `nftables` обычно уже есть вместе с `kmod-nft-tproxy`

Нужно поставить **вручную** (в пакете их нет, в официальных фидах их тоже может не быть):

- `xray` в `/usr/bin/xray`
- `geoip` и `geosite` в `/usr/share/xray/` (файлы `geoip.dat`, `geosite.dat`)
- по желанию: `hysteria` в `/usr/bin/hysteria` — только если пользуетесь кнопкой Hysteria2
- по желанию: `naive` в `/usr/bin/naive` — только если пользуетесь кнопкой Naive; ставится скриптом выше. Для распаковки архива нужен пакет `xz`.

Без `xray` и geo-файлов страница установится, но сохранить ссылку и включить прозрачный режим не получится.

## Репозиторий пакетов (опционально)

Адрес фида:

`https://raw.githubusercontent.com/Xstrwe/vless-router-panel/main/feed/all`

```sh
echo 'src/gz vless_panel https://raw.githubusercontent.com/Xstrwe/vless-router-panel/main/feed/all' >> /etc/opkg/customfeeds.conf
```

Фид **не подписан**. В OpenWrt 23.05 в `/etc/opkg.conf` обычно включено `option check_signature 1` (проверка usign). Этот флаг действует на **все** фиды сразу, отдельного выключателя «только для этого фида» нет. Поэтому `opkg update` выдаст ошибку подписи для `vless_panel`.

Что можно сделать:

1. **Лучше не добавлять фид**, а ставить и обновлять пакет по прямой ссылке на `.ipk` (команда в начале README). Для установки по URL подпись фида не нужна.
2. Если всё же хотите `opkg update` / `opkg upgrade vless-router-panel`:
   - временно закомментируйте `option check_signature 1` в `/etc/opkg.conf`;
   - выполните `opkg update && opkg install vless-router-panel`;
   - **верните** `option check_signature 1`, чтобы официальные фиды по-прежнему проверялись.

Не оставляйте проверку подписей выключенной.

## Update / Обновление

```sh
cd /tmp && wget -O vrp.ipk https://raw.githubusercontent.com/Xstrwe/vless-router-panel/main/feed/all/vless-router-panel_1.3.0_all.ipk && opkg install /tmp/vrp.ipk; rm -f /tmp/vrp.ipk
```

Либо, если фид настроен и проверка подписи временно снята: `opkg update && opkg upgrade vless-router-panel`.

При обновлении **не перезаписываются** пользовательские файлы, которых нет в пакете:

- `/etc/xray/link.txt`, `/etc/xray/config.json`, `/etc/xray/hy2.txt`
- `/etc/xray/naive.txt`, `/etc/xray/wg.conf`, `/etc/xray/wg.json`
- `/etc/xray/server_ip`, `/etc/xray/mode`, `/etc/xray/proto`
- `/etc/xray/httpd.conf`
- `/etc/hysteria/client.yaml`
- `/etc/naive/config.json`
- `/etc/xray/autoupdate/*.conf` и метки времени `.stamp`

Секция `uhttpd.vless`, если вы её уже меняли, тоже не трогается. Бинарь `/usr/bin/naive` пакет не удаляет и не заменяет.

## Uninstall / Удаление

```sh
opkg remove vless-router-panel
```

Удаляется секция `uhttpd.vless` (страница на :8088 перестаёт слушаться) и строка cron автообновления. Службы `xray`, Hysteria и Naive пакет сам не останавливает, чтобы не сбить уже работающий прозрачный режим. Пользовательские файлы из списка выше и `/usr/bin/naive` остаются на роутере; сотрите их вручную, если они больше не нужны.

## Auth / Пароль на страницу

Пакет **не придумывает пароль**. Если файла `/etc/xray/httpd.conf` ещё нет, `postinst` создаёт заготовку с комментариями, а базовая авторизация остаётся выключенной (в журнал ставится предупреждение). Пока в этом файле нет строки `/rfc2617`, страница доступна всем в LAN.

Чтобы включить логин:

```sh
uhttpd -m 'your-password'
# добавьте в /etc/xray/httpd.conf строку:
# /rfc2617 VLESS admin HASH
/etc/init.d/uhttpd restart
```

## Build / Сборка

```sh
./build.sh
```

Собирает воспроизводимый `.ipk` (внешний tar.gz с `./debian-binary`, `./control.tar.gz`, `./data.tar.gz`, владелец `root:root`) и индекс фида `feed/all/Packages` + `Packages.gz`. Скрипт сам распаковывает пакет и проверяет состав, права и синтаксис shell-скриптов (`sh -n`).

Исходники страницы и скриптов лежат в `files/`.

## License

MIT. См. [LICENSE](LICENSE).
