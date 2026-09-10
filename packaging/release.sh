#!/bin/bash
# GitHub Release oluşturur, DMG'yi yükler, DMG'nin sha256'sını hesaplayıp Cask
# dosyasındaki sha256 + version alanlarını günceller, sonra appcast.sh'ı çağırır.
#
# GERİ ALINAMAZ bir eylem (yayın): varsayılan olarak yalnız NE YAPACAĞINI yazar
# (kuru çalışma / dry-run). Gerçekten yayınlamak için:
#   RELEASE_CONFIRM=1 ./packaging/release.sh
#
# Önkoşullar:
#   - ./packaging/build.sh çalıştırılmış olmalı (build/PDF-Tools-<sürüm>.dmg mevcut).
#   - `gh auth status` ile GitHub CLI oturumu açık olmalı.
#   - Notarization isteniyorsa DMG önceden ./packaging/notarize.sh ile bilet almış olmalı
#     (bu betik notarization YAPMAZ, yalnız var olan DMG'yi yükler).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="${SPARKLE_APPCAST_REPO:-mehmetnadir/macos-free-pdf-toolkit}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
TAG="v${VERSION}"
DMG="build/PDF-Tools-${VERSION}.dmg"
CASK="Casks/pdf-tools.rb"
DRY_RUN=1
[ "${RELEASE_CONFIRM:-}" = "1" ] && DRY_RUN=0

echo "=== 1. Ön kontroller ==="
[ -f "$DMG" ] || { echo "HATA: $DMG yok — önce ./packaging/build.sh çalıştır." >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "HATA: gh (GitHub CLI) kurulu değil." >&2; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
  echo "HATA: gh oturumu açık değil — önce: gh auth login" >&2
  exit 1
fi
[ -f "$CASK" ] || { echo "HATA: $CASK yok." >&2; exit 1; }
echo "sürüm    : $VERSION"
echo "etiket   : $TAG"
echo "dmg      : $DMG"
echo "depo     : $REPO"

echo "=== 2. Zaten yayınlanmış mı? ==="
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "HATA: $TAG zaten yayınlanmış (gh release view $TAG başarılı döndü)." >&2
  echo "      Yeni bir sürüm yayınlamak için packaging/Info.plist içindeki" >&2
  echo "      CFBundleShortVersionString değerini artır." >&2
  exit 1
fi
echo "$TAG henüz yayınlanmamış — devam edilebilir."

if [ "$DRY_RUN" = "1" ]; then
  cat <<EOF

=== KURU ÇALIŞMA (RELEASE_CONFIRM=1 verilmedi) ===
Bu betik gerçekten koşarsa sırasıyla şunları yapacak:
  1. gh release create "$TAG" "$DMG" --repo "$REPO" \\
       --title "PDF Tools $VERSION" --generate-notes
  2. "$DMG" dosyasının sha256'sını hesaplayıp "$CASK" içindeki
     sha256 ve version alanlarını "$VERSION" ile güncelleyecek.
  3. ./packaging/appcast.sh çalıştırıp appcast.xml'i yeniden üretecek
     (Keychain'de Sparkle EdDSA anahtarı ister).

Gerçekten yayınlamak için:
  RELEASE_CONFIRM=1 ./packaging/release.sh

NOT: adım 1 GERİ ALINAMAZ bir GitHub Release oluşturur (silinebilir ama etiket
     genelde kalıcı kabul edilmeli) — bu yüzden onay olmadan koşmuyoruz.
EOF
  exit 0
fi

echo "=== 3. GitHub Release oluşturuluyor ($TAG) ==="
gh release create "$TAG" "$DMG" \
  --repo "$REPO" \
  --title "PDF Tools $VERSION" \
  --generate-notes

echo "=== 4. DMG sha256 hesaplanıyor ==="
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "sha256   : $SHA256"

echo "=== 5. Cask dosyası güncelleniyor ($CASK) ==="
# Hem version hem sha256 satırını değiştiriyoruz — release her zaman Info.plist'teki
# güncel sürüm için koşulduğundan version satırı burada VERSION ile birebir eşleşmeli.
/usr/bin/python3 - "$CASK" "$VERSION" "$SHA256" <<'PYEOF'
import re
import sys

path, version, sha256 = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

content, n_version = re.subn(
    r'version\s+"[^"]*"', f'version "{version}"', content, count=1
)
content, n_sha = re.subn(
    r'sha256\s+"[^"]*"', f'sha256 "{sha256}"', content, count=1
)
if n_version != 1 or n_sha != 1:
    sys.stderr.write(
        f"HATA: {path} içinde version ({n_version} eşleşme) veya sha256 "
        f"({n_sha} eşleşme) satırı beklenen tek eşleşmeyi vermedi.\n"
    )
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
echo "güncellendi: $CASK (version=$VERSION, sha256=$SHA256)"

echo "=== 6. appcast üretiliyor ==="
./packaging/appcast.sh

echo "=== Özet ==="
echo "Yayınlandı : $TAG ($REPO)"
echo "Cask       : $CASK güncellendi — commit+push GEREKLİ (bu betik commit atmaz)."
echo "Appcast    : appcast.xml güncellendi — commit+push GEREKLİ."
echo "NOT: tap deposu ayrı bir repo ise $CASK dosyasını oraya da kopyala/senkronize et."
