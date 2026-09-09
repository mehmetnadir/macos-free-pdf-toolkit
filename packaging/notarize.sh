#!/bin/bash
# Apple notarization — kullanıcının uygulamayı TEK TIKLA açabilmesi için zorunlu.
# macOS 15 Sequoia'dan beri Control-tık ile Gatekeeper atlama kaldırıldı: notarize
# edilmemiş uygulama için kullanıcı Sistem Ayarları > Gizlilik ve Güvenlik'e gitmek
# zorunda kalır. Notarize + staple ile çift tık yeter.
#
# TEK SEFERLİK ÖN HAZIRLIK (Apple ID uygulama parolası appleid.apple.com'dan alınır):
#   xcrun notarytool store-credentials "pdftools-notary" \
#     --apple-id <APPLE_ID> --team-id 335PPR74QM --password <APP_SPECIFIC_PASSWORD>
#
# Akış: .app'i notarize + staple → DMG'yi yeniden üret + imzala → DMG'yi notarize + staple.
# İki aşamalı olmasının nedeni: DMG'ye yapıştırılan bilet, uygulama /Applications'a
# kopyalandıktan sonra çevrimdışı doğrulamada geçerli olmaz; .app kendi biletini taşımalı.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="PDF Tools"
APP="build/${APP_NAME}.app"
TEAM_ID="${TEAM_ID:-335PPR74QM}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-pdftools-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
DMG="build/PDF-Tools-${VERSION}.dmg"
ZIP="build/PDFTools-${VERSION}-notarize.zip"

echo "=== 1. Ön kontroller ==="
[ -d "$APP" ] || { echo "HATA: $APP yok — önce SIGN_IDENTITY=... ./packaging/build.sh" >&2; exit 1; }

if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
[ -n "$SIGN_IDENTITY" ] || { echo "HATA: Developer ID Application sertifikası bulunamadı" >&2; exit 1; }
echo "Kimlik: $SIGN_IDENTITY"

# Notarization yalnızca hardened runtime + güvenli zaman damgası ile imzalanmış pakete verilir.
if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
  echo "HATA: $APP hardened runtime ile imzalanmamış." >&2
  echo "      SIGN_IDENTITY=\"$SIGN_IDENTITY\" ./packaging/build.sh ile yeniden derle." >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
HATA: '$KEYCHAIN_PROFILE' notarytool profili yok.
Apple ID uygulama parolası (app-specific password) https://appleid.apple.com adresinden
"Uygulamaya Özel Parolalar" bölümünden alınır, sonra tek seferlik:

  xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \\
    --apple-id <APPLE_ID> --team-id $TEAM_ID --password <APP_SPECIFIC_PASSWORD>
EOF
  exit 1
fi

echo "=== 2. .app notarize ediliyor ==="
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
rm -f "$ZIP"

echo "=== 3. .app'e bilet yapıştırılıyor (staple) ==="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "=== 4. DMG yeniden üretiliyor (biletli .app ile) ==="
SIGN_IDENTITY="$SIGN_IDENTITY" ./packaging/make-dmg.sh

echo "=== 5. DMG notarize ediliyor ==="
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "=== 6. Gatekeeper doğrulaması ==="
spctl --assess --type execute --verbose=2 "$APP"

echo "=== Bitti ==="
echo "Dağıtıma hazır: $ROOT/$DMG"
echo "Kullanıcı DMG'yi açıp uygulamayı Applications'a sürükler; çift tıkla açılır."
