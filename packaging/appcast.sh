#!/bin/bash
# Sparkle appcast.xml üretir/günceller. `generate_appcast` aracını kullanır
# (build/ içindeki DMG'yi tarar, EdDSA ile imzalar, indirme linklerini GitHub
# Releases'e göre yazar). Önkoşul: özel EdDSA anahtarı Keychain'de olmalı —
# yoksa önce ./packaging/sparkle-keys.sh çalıştırılmalı.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Değiştirmek için env ile ez: SPARKLE_APPCAST_REPO=... ./packaging/appcast.sh
REPO="${SPARKLE_APPCAST_REPO:-mehmetnadir/macos-free-pdf-toolkit}"
ARCHIVES_DIR="${SPARKLE_ARCHIVES_DIR:-build}"
OUT="$ROOT/appcast.xml"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
DMG="$ARCHIVES_DIR/PDF-Tools-${VERSION}.dmg"

echo "=== 1. generate_appcast aracı aranıyor ==="
# SwiftPM checkout'unda ya da Sparkle'ın kendi release arşivinde (Sparkle-<sürüm>.tar.xz
# içindeki bin/generate_appcast) bulunabilir — tahmin etmiyoruz, gerçekten arıyoruz.
GEN="$(find .build -maxdepth 8 -type f -name "generate_appcast" 2>/dev/null | head -1)"
if [ -z "$GEN" ]; then
  cat >&2 <<EOF
HATA: generate_appcast aracı bulunamadı (.build altında arandı).
Olası sebep: Sparkle henüz Package.swift'e eklenmemiş (paralel bir ajan ekliyor
olabilir) ya da SwiftPM checkout'unda bu araç yer almıyor.

Manuel kurulum:
  1. https://github.com/sparkle-project/Sparkle/releases adresinden
     Sparkle-<sürüm>.tar.xz indir.
  2. Arşivdeki bin/generate_appcast dosyasını kullan, ör:
     <indirilen-yol>/bin/generate_appcast \\
       --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \\
       -o "$OUT" "$ARCHIVES_DIR"
EOF
  exit 1
fi
echo "bulundu: $GEN"
[ -x "$GEN" ] || chmod +x "$GEN"

echo "=== 2. DMG kontrolü ==="
if [ ! -f "$DMG" ]; then
  echo "HATA: $DMG yok." >&2
  echo "      Önce paketi üret: ./packaging/build.sh (dağıtım için SIGN_IDENTITY=... + notarize.sh)." >&2
  exit 1
fi
echo "girdi: $DMG"

echo "=== 3. EdDSA anahtarı (Keychain) — ön kontrol ==="
# generate_appcast özel anahtarı kendi başına Keychain'den okur; burada yalnız
# erken/anlaşılır bir uyarı vermek için genel bir arama yapılır (kesin gate değil —
# generate_appcast'in kendi hata mesajı asıl otorite).
if ! security dump-keychain 2>/dev/null | grep -qi "sparkle"; then
  echo "UYARI: Keychain'de Sparkle'a ait bir anahtar görünmüyor." >&2
  echo "       Yoksa önce çalıştır: ./packaging/sparkle-keys.sh" >&2
fi

echo "=== 4. appcast üretiliyor ==="
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/v${VERSION}/"
"$GEN" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o "$OUT" \
  "$ARCHIVES_DIR"

echo "=== Özet ==="
echo "appcast  : $OUT"
echo "feed URL : https://raw.githubusercontent.com/${REPO}/main/appcast.xml"
echo "indirme  : ${DOWNLOAD_PREFIX}$(basename "$DMG")"
echo "NOT: appcast.xml'in çalışması için v${VERSION} etiketi + $(basename "$DMG")"
echo "     dosyası GitHub Releases'e yüklenmiş olmalı, sonra appcast.xml commit+push edilmeli."
echo "NOT: yalnız $ARCHIVES_DIR içindeki DMG(ler) tarandı — önceki sürümlerin de appcast'te"
echo "     kalması isteniyorsa onların DMG'leri de aynı klasörde (ya da SPARKLE_ARCHIVES_DIR"
echo "     ile gösterilen kalıcı bir arşiv klasöründe) bulunmalı."
