# SHIN VPN

کلاینت VPN با Flutter و هستهٔ Xray برای اندروید.

## ساخت

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

بیلد Release به فایل `android/key.properties` نیاز دارد (در Git قرار نمی‌گیرد). در GitHub Actions این فایل از Secrets ساخته می‌شود:

| Secret | توضیح |
|---|---|
| `KEYSTORE_BASE64` | فایل `.jks` به صورت base64 |
| `KEYSTORE_PASSWORD` | رمز keystore |
| `KEY_ALIAS` | alias کلید |
| `KEY_PASSWORD` | رمز کلید |

ساخت keystore (فقط یک بار، و نگه‌داری نسخهٔ پشتیبان آن ضروری است):

```bash
keytool -genkey -v -keystore shin-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias shin
base64 -w0 shin-release.jks   # مقدار KEYSTORE_BASE64
```

اگر keystore عوض شود، کاربران موجود باید برنامه را یک بار حذف و دوباره نصب کنند.

## انتشار نسخهٔ جدید

1. `version` در `pubspec.yaml` را بالا ببرید. شمارهٔ بیلد (بعد از `+`) باید همیشه از نسخهٔ قبلی بزرگ‌تر باشد.
2. `kAppVersion` در `lib/main.dart` را همان نسخه قرار دهید.
3. تغییرات را push کنید و یک تگ بسازید:

```bash
git tag v1.00.1
git push origin v1.00.1
```

workflow به‌صورت خودکار APKها را می‌سازد و یک GitHub Release با همان APKها منتشر می‌کند. برنامه‌های نصب‌شده نسخهٔ جدید را از همین Release پیدا و نصب می‌کنند.

## ساختار مهم

- `lib/main.dart`: کل منطق و رابط کاربری
- `android/app/src/main/kotlin/.../MainActivity.kt`: کانال نصب APK و تنظیمات Quick Settings
- `android/app/src/main/kotlin/.../VpnQuickSettingsTileService.kt`: کاشی Quick Settings
- `.github/workflows/android.yml`: بیلد، امضا و انتشار
