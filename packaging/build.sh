#!/bin/bash
# .app paketi üretir: swift build (universal) + motorlar + ikon + imza.
# SIGN_IDENTITY verilmezse ad-hoc imzalanır (yerel kullanım). Dağıtım için:
#   SIGN_IDENTITY="Developer ID Application: ..." ./packaging/build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP_NAME="PDF Tools"
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
# SwiftPM kaynak paketleri (Bundle.module) — çeviri tabloları burada yaşıyor.
# ZORUNLU: `Bundle.module` bulunamazsa SwiftPM'in ürettiği erişimci fatalError atar, yani
# uygulama AÇILIŞTA ÇÖKER. Ayrıca paket kopyalanıp da içindeki .lproj eksikse çökme olmaz,
# arayüz SESSİZCE İngilizce kalır — o yüzden hem varlık hem içerik denetleniyor.
for bundle in "$BIN"/PDFTools_PDFToolsApp.bundle "$BIN"/PDFTools_PDFToolsCore.bundle; do
  [ -d "$bundle" ] || { echo "HATA: $bundle yok — kaynak paketi üretilmemiş" >&2; exit 1; }
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
for bundle in "$APP/Contents/Resources"/PDFTools_*.bundle; do
  if ! find "$bundle" -name "Localizable.strings" -path "*tr.lproj*" | grep -q .; then
    echo "HATA: $(basename "$bundle") içinde tr.lproj/Localizable.strings yok —" >&2
    echo "      Türkçe seçildiğinde arayüz sessizce İngilizce kalırdı." >&2
    exit 1
  fi
done
echo "kaynak paketleri kopyalandı (tr.lproj doğrulandı)"

# Sparkle.framework (varsa) — paralel bir ajan Package.swift'e ekliyor olabilir; henüz
# eklenmemişse otomatik güncelleme OLMADAN paketlenir (regresyon yok, betik yine tamamlanır).
# symlink yapısı (Versions/Current -> sürüm dizini) korunmalı diye `cp -R` değil `ditto`.
# Kaynak SEÇİMİ BELİRLİ olmak zorunda: `find | head -1` debug derlemesinin arm64-only
# kopyasını seçebilir ve evrensel paketin içine tek mimarili framework girer — DMG
# "universal" görünür, Intel'de çöker (sessiz bozulma). Bu yüzden önce XCFramework'ün
# arm64_x86_64 dilimi, sonra release ürünü aranır; seçilen dilimin mimarisi ÖLÇÜLÜR.
SPARKLE_FRAMEWORK=""
for candidate in \
  .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
  .build/apple/Products/Release/Frameworks/Sparkle.framework \
  .build/apple/Products/Release/Sparkle.framework; do
  [ -d "$candidate" ] && { SPARKLE_FRAMEWORK="$candidate"; break; }
done
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  echo "Sparkle.framework bulundu: $SPARKLE_FRAMEWORK"
  mkdir -p "$APP/Contents/Frameworks"
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
  # Mimari kapısı: uygulama ikilisi evrensel derlendiyse framework de evrensel olmalı.
  APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/PDFToolsApp" 2>/dev/null || echo "?")"
  # Sürüm dizini adı Sparkle sürümüyle değişiyor (2.9.6'da Versions/B) — bu yüzden
  # "Versions/A" gibi sabit bir yol DEĞİL, framework'ün üst düzey sembolik bağı okunur.
  FW_ARCHS="$(lipo -archs "$APP/Contents/Frameworks/Sparkle.framework/Sparkle" \
    2>/dev/null || echo "?")"
  echo "mimari — uygulama: $APP_ARCHS | Sparkle: $FW_ARCHS"
  for arch in $APP_ARCHS; do
    case " $FW_ARCHS " in
      *" $arch "*) ;;
      *)
        echo "HATA: uygulama $arch içeriyor ama Sparkle.framework içermiyor ($FW_ARCHS)." >&2
        echo "      Bu paket $arch makinede güncelleme yüklemeye çalışırken çöker." >&2
        exit 1
        ;;
    esac
  done
else
  echo "UYARI: Sparkle.framework bulunamadı — otomatik güncelleme OLMADAN paketleniyor"
  echo "       (Package.swift'e Sparkle bağımlılığı henüz eklenmemiş olabilir)"
fi

echo "=== 5. İmza ($SIGN_IDENTITY) ==="
SIGN_OPTS=(--force --sign "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" != "-" ] && SIGN_OPTS+=(--options runtime --timestamp)
for f in "$APP/Contents/Resources/bin/"* "$APP/Contents/MacOS/pdftools" "$APP/Contents/MacOS/PDFToolsApp"; do
  codesign "${SIGN_OPTS[@]}" "$f"
done
# İç içe paketler (kaynak paketleri) kendi imzalarını taşımak zorunda; yoksa
# `codesign --verify --deep` dış imzayı geçersiz sayar.
for bundle in "$APP/Contents/Resources"/PDFTools_*.bundle; do
  codesign "${SIGN_OPTS[@]}" "$bundle"
done
# Sparkle.framework gömülüyse: en içteki parçalar önce, framework en son (Apple'ın "inside-out"
# imzalama sırası). Framework'ün kendi imzası olabileceğinden SIGN_OPTS'taki --force şart.
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  FW_DEST="$APP/Contents/Frameworks/Sparkle.framework"
  echo "--- Sparkle.framework içi imzalanıyor ---"
  while IFS= read -r -d '' xpc; do
    codesign "${SIGN_OPTS[@]}" "$xpc"
  done < <(find "$FW_DEST" -maxdepth 4 -name "*.xpc" -print0 2>/dev/null)
  AUTOUPDATE="$(find "$FW_DEST" -maxdepth 4 -name "Autoupdate" -type f 2>/dev/null | head -1)"
  [ -n "$AUTOUPDATE" ] && codesign "${SIGN_OPTS[@]}" "$AUTOUPDATE"
  UPDATER_APP="$(find "$FW_DEST" -maxdepth 4 -name "Updater.app" -type d 2>/dev/null | head -1)"
  [ -n "$UPDATER_APP" ] && codesign "${SIGN_OPTS[@]}" "$UPDATER_APP"
  codesign "${SIGN_OPTS[@]}" "$FW_DEST"
fi
codesign "${SIGN_OPTS[@]}" "$APP"
codesign --verify --strict --deep "$APP" && echo "imza doğrulandı (--deep)"

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

echo "=== 7. Açılış duman testi ==="
# "Süreç ayakta ama HİÇ pencere yok" arızası sessizdir: çökme yok, log yok, uygulama
# olay döngüsünde boşta bekler (ölçüldü 2026-09-09 — AppKit'in açılıştaki pencere-restore
# yarışı; ayrıntı .claude/docs/yol-haritasi-2026-09.md). Bu yüzden paketi GERÇEKTEN açıp
# pencere sayıyoruz. `open -g` kullanıcının odağını çalmaz.
if [ -n "${PDFTOOLS_SKIP_SMOKE:-}" ]; then
  echo "atlandı (PDFTOOLS_SKIP_SMOKE)"
elif [ "$(launchctl managername 2>/dev/null)" != "Aqua" ]; then
  echo "atlandı: GUI oturumu yok (SSH/CI) — pencere testi yalnız masaüstünde anlamlı"
else
  open -g -n "$APP"
  sleep 6
  SMOKE_PID="$(pgrep -f "$APP/Contents/MacOS/PDFToolsApp" | head -1)"
  if [ -z "$SMOKE_PID" ]; then
    echo "HATA: uygulama açılmadı (süreç yok)" >&2
    # `open -g` GUI üzerinden başlatıldığı için çökme çıktısı bu kabuğa akmaz (LaunchServices
    # ayrı bir süreç ağacı); dyld/crash nedenini unified log'dan çekip göster (yalnız teşhis,
    # bulunamazsa sessizce geçilir).
    log show --last 20s --predicate 'process == "PDFToolsApp"' --style compact 2>/dev/null \
      | grep -iE "dyld|library not loaded|terminat|crash" | tail -5 >&2 || true
    exit 1
  fi
  WINDOWS="$(swift packaging/window-count.swift "$SMOKE_PID" 2>/dev/null || echo 0)"
  kill "$SMOKE_PID" 2>/dev/null || true
  if [ "$WINDOWS" -lt 1 ]; then
    echo "HATA: uygulama açıldı ama HİÇ pencere kurmadı (kurtarma ağı da devreye girmedi)." >&2
    echo "      Bkz. AppDelegate.applicationDidFinishLaunching güvenlik ağı." >&2
    exit 1
  fi
  echo "pencere sayısı: $WINDOWS ✓"
fi
