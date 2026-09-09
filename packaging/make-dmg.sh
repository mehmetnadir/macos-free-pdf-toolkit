#!/bin/bash
# build/<APP_NAME>.app'ten dağıtıma hazır DMG üretir ve (Developer ID varsa) imzalar.
# build.sh ve notarize.sh tarafından çağrılır; tek başına da çalışır.
#   SIGN_IDENTITY="Developer ID Application: ..." ./packaging/make-dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="PDF Tools"
APP="build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
DMG="build/PDF-Tools-${VERSION}.dmg"
STAGING="build/dmg-staging"

[ -d "$APP" ] || { echo "HATA: $APP yok — önce ./packaging/build.sh" >&2; exit 1; }

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG"
  codesign --verify --strict "$DMG" && echo "DMG imzalandı: $SIGN_IDENTITY"
else
  echo "UYARI: DMG imzasız (SIGN_IDENTITY verilmedi) — yalnızca yerel kullanım"
fi

echo "DMG: $ROOT/$DMG"
du -sh "$DMG"
