# Свой IPA для iPhone (VLESS + REALITY)

Собираем **SFI** — официальный iOS-клиент [sing-box](https://github.com/SagerNet/sing-box-for-apple).
Протоколы те же, что на каскаде: VLESS, REALITY, подписка / `vless://`.

GitHub собирает **неподписанный** `.ipa`. Подпись — у тебя в ESign / Feather / KSign **своим** `.p12` (в профиле должен быть VPN / `packet-tunnel-provider`).

Этот каталог — **отдельный GitHub-репозиторий**, не ютуб-проект. В корне ютуб-папки git сейчас нет: Actions живёт только после `git init` + push на GitHub **из папки `ios-vpn`**.

## Цепочка

```text
этот репозиторий
  → GitHub Actions (macos)
  → SFI-unsigned.ipa  (артефакт)
  → ESign на айфоне подписывает
  → ставится, импорт vless:// или URL подписки из 3x-ui
```

## Один раз: репозиторий

В PowerShell из этой папки:

```powershell
cd "$env:USERPROFILE\Desktop\ютуб\ios-vpn"
git init
git add .
git commit -m "SFI unsigned IPA workflow"
```

Дальше создай **пустой** репозиторий на GitHub и:

```powershell
git remote add origin https://github.com/USER/REPO.git
git branch -M main
git push -u origin main
```

Публичный репозиторий: минуты macos у GitHub бесплатные. Приватный — лимит короткий (macos жрёт их ×10).

## Сборка IPA

1. GitHub → **Actions** → **Build unsigned IPA** → **Run workflow**.
2. Ждать 20–40 минут.
3. Скачать артефакт `SFI-unsigned.ipa`.

## Подпись на айфоне

1. Поставить ESign / Feather (тем сертификатом, которым потом будешь жить).
2. Импорт `.p12` + `.mobileprovision`.
3. Импорт `SFI-unsigned.ipa` → Sign.
4. Не снимать plugin / Network Extension. Туннель лежит в `.appex` внутри IPA.
5. После установки: Настройки → Основные → VPN и управление устройством → Доверять.
6. В приложении: профиль / подписка с панели (тот же вход, что в Hiddify).

Если приложение открывается, а VPN не поднимается — в **provisioning profile этого сертификата нет** `packet-tunnel-provider`. Другой серт, не «починить сборкой».

## Что не кладём сюда

- `.p12`, пароли, живые `vless://`, UUID с панели.
- Антиотзыв-DNS и чужие сертификаты — это не часть сборки.

## Дальше (когда IPA уже встаёт)

- Свой display name / иконка.
- Зашить URL подписки (без секретов в git — через GitHub Secret на этапе сборки, если надо).
- Форк upstream и свои правки UI.
