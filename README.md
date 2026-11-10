# vless-router-panel

Панель **«VLESS на роутере»** для OpenWrt / GL.iNet: веб-страница на `http://192.168.8.1:8088` для включения и выключения прозрачного прокси, теста подключения и скорости, сохранения ссылок `vless://` и `hysteria2://`.

Это пакет **`.ipk`** для `opkg`, не `.deb`. На OpenWrt (в том числе GL.iNet GL-BE6500, OpenWrt 23.05, `aarch64_cortex-a53`) пакеты ставятся через `opkg`. Архитектура пакета — `all`: внутри только скрипты.

Репозиторий публичный и не содержит секретов: ни ссылок, ни паролей, ни `config.json`.

---

A small OpenWrt web panel for toggling a transparent VLESS/Hysteria2 proxy, testing the connection and speed, and saving `vless://` / `hysteria2://` links. Ships as an `.ipk` (`Architecture: all`) and an unsigned `opkg` feed. No user secrets are included in the package or this repository.

## Requirements / Требования

Ставятся из обычных фидов OpenWrt (зависимости пакета):

- `curl`, `jq`, `ucode`, `uhttpd`, `kmod-nft-tproxy`
- `nftables` обычно уже есть вместе с `kmod-nft-tproxy`

Нужно поставить **вручную** (в пакете их нет, в официальных фидах их тоже может не быть):

- `xray` в `/usr/bin/xray`
- `geoip` и `geosite` в `/usr/share/xray/` (файлы `geoip.dat`, `geosite.dat`)
- по желанию: `hysteria` в `/usr/bin/hysteria` — только если пользуетесь кнопкой Hysteria2

Без `xray` и geo-файлов страница установится, но сохранить ссылку и включить прозрачный режим не получится.

## Install / Установка

Рекомендуемый способ — прямая установка `.ipk` по URL. Так не нужно отключать проверку подписей фидов:

```sh
opkg update
opkg install https://raw.githubusercontent.com/Xstrwe/vless-router-panel/main/feed/all/vless-router-panel_1.0.0_all.ipk
```

После установки откройте `http://192.168.8.1:8088`. Если LAN-адрес роутера другой, поправьте `uhttpd.vless.listen_http` через `uci` и перезапустите `uhttpd`.

### Репозиторий пакетов (опционально)

Адрес фида:

`https://raw.githubusercontent.com/Xstrwe/vless-router-panel/main/feed/all`

```sh
echo 'src/gz vless_panel https://raw.githubusercontent.com/Xstrwe/vless-router-panel/main/feed/all' >> /etc/opkg/customfeeds.conf
```

Фид **не подписан**. В OpenWrt 23.05 в `/etc/opkg.conf` обычно включено `option check_signature 1` (проверка usign). Этот флаг действует на **все** фиды сразу, отдельного выключателя «только для этого фида» нет. Поэтому `opkg update` выдаст ошибку подписи для `vless_panel`.

Что можно сделать:

1. **Лучше не добавлять фид**, а ставить и обновлять пакет по прямой ссылке на `.ipk` (команда выше). Для установки по URL подпись фида не нужна.
2. Если всё же хотите `opkg update` / `opkg upgrade vless-router-panel`:
   - временно закомментируйте `option check_signature 1` в `/etc/opkg.conf`;
   - выполните `opkg update && opkg install vless-router-panel`;
   - **верните** `option check_signature 1`, чтобы официальные фиды по-прежнему проверялись.

Не оставляйте проверку подписей выключенной.

## Update / Обновление

```sh
opkg install https://raw.githubusercontent.com/Xstrwe/vless-router-panel/main/feed/all/vless-router-panel_1.0.0_all.ipk
```

Либо, если фид настроен и проверка подписи временно снята: `opkg update && opkg upgrade vless-router-panel`.

При обновлении **не перезаписываются** пользовательские файлы, которых нет в пакете:

- `/etc/xray/link.txt`, `/etc/xray/config.json`, `/etc/xray/hy2.txt`
- `/etc/xray/server_ip`, `/etc/xray/mode`, `/etc/xray/proto`
- `/etc/xray/httpd.conf`
- `/etc/hysteria/client.yaml`

Секция `uhttpd.vless`, если вы её уже меняли, тоже не трогается.

## Uninstall / Удаление

```sh
opkg remove vless-router-panel
```

Удаляется секция `uhttpd.vless` (страница на :8088 перестаёт слушаться). Службы `xray` и Hysteria пакет сам не останавливает, чтобы не сбить уже работающий прозрачный режим. Пользовательские файлы из списка выше остаются на роутере; сотрите их вручную, если они больше не нужны.

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

Собирает воспроизводимый `.ipk` (внешний tar.gz с `./debian-binary`, `./control.tar.gz`, `./data.tar.gz`, владелец `root:root`) и индекс фида `feed/all/Packages` + `Packages.gz`. Скрипт сам распаковывает пакет и проверяет состав и права.

Исходники страницы и скриптов лежат в `files/`.

## License

MIT. См. [LICENSE](LICENSE).
