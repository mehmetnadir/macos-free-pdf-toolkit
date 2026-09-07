#!/bin/bash
# .app paketi üretir: swift build (universal) + motorlar + ikon + imza.
# SIGN_IDENTITY verilmezse ad-hoc imzalanır (yerel kullanım). Dağıtım için:
#   SIGN_IDENTITY="Developer ID Application: ..." ./packaging/build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP_NAME="PDF Araçları"
APP="build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"

echo "=== 1. Motorlar ==="
if [ ! -x vendor/bin/qpdf ] && [ ! -x vendor/bin/pdfcpu ]; then
  ./packaging/build-engines.sh
fi
ls -la vendor/bin

echo "=== 2. Swift build (universal) ==="
if swift build -c release --arch arm64 --arch x86_64 >/dev/null; then
  BIN=".build/apple/Products/Release"
else
  if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "HATA: universal derleme başarısız; Developer ID ile tek mimarili paket dağıtılmaz" >&2
    exit 1
  fi
  echo "UYARI: universal derleme başarısız, host mimarisine düşülüyor (yalnızca yerel/ad-hoc)"
  swift build -c release >/dev/null
  BIN=".build/release"
fi
[ -f "$BIN/PDFToolsApp" ] || { echo "HATA: PDFToolsApp yok ($BIN)"; exit 1; }

echo "=== 3. İkon ==="
if [ ! -f build/AppIcon.icns ]; then
  mkdir -p build
  swift packaging/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "=== 4. Paket ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/PDFToolsApp" "$APP/Contents/MacOS/"
cp "$BIN/pdftools" "$APP/Contents/MacOS/"
cp vendor/bin/* "$APP/Contents/Resources/bin/"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$APP/Contents/PkgInfo"
# Dağıtılan qpdf/pdfcpu/libjpeg-turbo ikililerinin lisans metinleri (Apache-2.0 + IJG/BSD gereği)
if [ -d vendor/licenses ]; then
  mkdir -p "$APP/Contents/Resources/licenses"
  cp vendor/licenses/* "$APP/Contents/Resources/licenses/"
fi

echo "=== 5. İmza ($SIGN_IDENTITY) ==="
SIGN_OPTS=(--force --sign "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" != "-" ] && SIGN_OPTS+=(--options runtime --timestamp)
for f in "$APP/Contents/Resources/bin/"* "$APP/Contents/MacOS/pdftools" "$APP/Contents/MacOS/PDFToolsApp"; do
  codesign "${SIGN_OPTS[@]}" "$f"
done
codesign "${SIGN_OPTS[@]}" "$APP"
codesign --verify --strict "$APP" && echo "imza doğrulandı"

echo "=== 6. DMG ==="
SIGN_IDENTITY="$SIGN_IDENTITY" ./packaging/make-dmg.sh

echo "=== Özet ==="
echo "Sürüm : $VERSION"
echo "Paket : $ROOT/$APP"
du -sh "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "NOT: ad-hoc imza. Dağıtım için: SIGN_IDENTITY=\"Developer ID Application: ...\" ./packaging/build.sh"
  echo "     ardından ./packaging/notarize.sh (tek tıkla açılması için notarization şart)."
fi
