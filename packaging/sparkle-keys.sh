#!/bin/bash
# Sparkle EdDSA imzalama anahtarını üretir/okur (generate_keys). ÖZEL anahtar
# Keychain'de saklanır — bu betik onu ASLA ekrana basmaz, dosyaya yazmaz, log'lamaz.
# Yalnız ÜRETİLEN AÇIK (public) anahtar basılır; bu değer packaging/Info.plist
# içindeki SUPublicEDKey alanına yazılır (Info.plist bu betikte DEĞİŞTİRİLMEZ —
# elle ya da ilgili ajan tarafından güncellenmeli).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== generate_keys aracı aranıyor ==="
GEN="$(find .build -maxdepth 8 -type f -name "generate_keys" 2>/dev/null | head -1)"
if [ -z "$GEN" ]; then
  cat >&2 <<'EOF'
HATA: generate_keys aracı bulunamadı (.build altında arandı).
Olası sebep: Sparkle henüz Package.swift'e eklenmemiş (paralel bir ajan ekliyor
olabilir) ya da SwiftPM checkout'unda bu araç yer almıyor.

Manuel kurulum:
  1. https://github.com/sparkle-project/Sparkle/releases adresinden
     Sparkle-<sürüm>.tar.xz indir.
  2. Arşivdeki bin/generate_keys dosyasını çalıştır.
EOF
  exit 1
fi
echo "bulundu: $GEN"
[ -x "$GEN" ] || chmod +x "$GEN"

echo "=== Anahtar üretiliyor/okunuyor ==="
echo "(anahtar zaten Keychain'de varsa generate_keys onu ÜRETMEZ, mevcut AÇIK anahtarı basar)"
"$GEN"

echo
echo "=== Sonraki adım ==="
echo "Yukarıda basılan AÇIK anahtarı packaging/Info.plist içindeki SUPublicEDKey"
echo "alanına yapıştır. Özel anahtar bu Mac'in Keychain'inde kalır; imzalama"
echo "(appcast.sh / generate_appcast) yalnız BU makinede yapılabilir."
