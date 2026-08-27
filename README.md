# Unsigned iOS IPA

GitHub Actions builds [Libbox](https://github.com/SagerNet/sing-box) then an unsigned `.ipa` of [SFI](https://github.com/SagerNet/sing-box-for-apple) (scheme `SFI`).
Sign it on device with ESign / Feather / KSign using your own `.p12` and `.mobileprovision`.

## Build

1. **Actions** → **Build unsigned IPA** → **Run workflow**
2. Wait 40–70 minutes (`macos-26`: Libbox + Xcode 26)
3. Download artifact `SFI-unsigned-macos-26`

## Sign and install

1. Import `.p12` + `.mobileprovision` into the signer
2. Import `SFI-unsigned.ipa` → Sign (keep `.appex` plugins)
3. Settings → General → Device Management → Trust the developer
4. Open the app and add a profile

## Flashlight test app

1. **Actions** → **Build unsigned flashlight** → **Run workflow**
2. Wait about 5 minutes (`macos-15`)
3. Download artifact `Flashlight-unsigned`
4. Sign in ESign the same way. There is no `.appex`. Change the bundle ID to match your provision if asked.

Do not commit `.p12`, passwords, or live configs.
