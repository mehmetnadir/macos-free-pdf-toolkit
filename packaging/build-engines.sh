#!/bin/bash
# Motor derleme: qpdf (statik, universal) + pdfcpu (universal) -> vendor/bin
# Tekrarlanabilir; internet gerektirir. Çıktı: vendor/bin/qpdf, vendor/bin/pdfcpu
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/vendor/bin"
WORK="$ROOT/.build/engines"
ARCHS="arm64;x86_64"
DEPLOY="14.0"
QPDF_VER="${QPDF_VER:-12.4.1}"
JPEG_VER="${JPEG_VER:-$(gh release view -R libjpeg-turbo/libjpeg-turbo --json tagName -q .tagName 2>/dev/null || echo 3.1.2)}"
PDFCPU_VER="${PDFCPU_VER:-latest}"
mkdir -p "$OUT" "$WORK"
cd "$WORK"

echo "=== cmake ==="
if ! command -v cmake >/dev/null; then
  [ -x venv/bin/cmake ] || { python3 -m venv venv && venv/bin/pip -q install cmake ninja; }
  export PATH="$WORK/venv/bin:$PATH"
fi
cmake --version | head -1

echo "=== libjpeg-turbo $JPEG_VER (statik; mimari başına derlenip lipo ile birleşir) ==="
if [ ! -f prefix/lib/libjpeg.a ]; then
  [ -d "libjpeg-turbo-$JPEG_VER" ] || curl -fsSL "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VER/libjpeg-turbo-$JPEG_VER.tar.gz" | tar xz
  for arch in arm64 x86_64; do
    cmake -S "libjpeg-turbo-$JPEG_VER" -B "jpeg-build-$arch" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
      -DWITH_SIMD=0 -DENABLE_SHARED=0 -DENABLE_STATIC=1 -DWITH_TURBOJPEG=0 \
      -DCMAKE_INSTALL_PREFIX="$WORK/prefix-$arch" >/dev/null
    cmake --build "jpeg-build-$arch" -j"$(sysctl -n hw.ncpu)" >/dev/null
    cmake --install "jpeg-build-$arch" >/dev/null
  done
  mkdir -p prefix/lib
  cp -R prefix-arm64/include prefix/
  lipo -create prefix-arm64/lib/libjpeg.a prefix-x86_64/lib/libjpeg.a -output prefix/lib/libjpeg.a
fi
# libjpeg-turbo'nun .pc dosyası mutlak (tek mimarili) yollar yazar; fat prefix'i gösteren temiz bir .pc
# HER ÇALIŞTIRMADA yeniden üretilir (libjpeg.a önceden derlenmiş olsa bile) — aksi halde eski/elle
# düzeltilmiş bir .pc diskte kalıp qpdf'in pkg-config sonucunu sessizce bozabilir. qpdf'in
# libqpdf/CMakeLists.txt'i pkg_check_modules çıktısından yalnızca "-lxxx" biçimli token'ları
# dep_link_libraries'e ekliyor; Libs alanı mutlak yol (".../libjpeg.a") olursa bu token FindPkgConfig
# tarafından *_LDFLAGS_OTHER'a düşer, *_LIBRARIES'e değil — qpdf CLI linkinde -ljpeg hiç görünmez.
mkdir -p prefix/lib/pkgconfig
cat > prefix/lib/pkgconfig/libjpeg.pc <<PC
prefix=$WORK/prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libjpeg
Description: libjpeg-turbo (static, universal)
Version: $JPEG_VER
Libs: -L\${libdir} -ljpeg
Cflags: -I\${includedir}
PC
lipo -info prefix/lib/libjpeg.a

echo "=== pdfcpu $PDFCPU_VER (universal, CGO kapalı) ==="
mkdir -p pdfcpu-mod && cd pdfcpu-mod
[ -f go.mod ] || go mod init pdfcpu-vendor >/dev/null
go get "github.com/pdfcpu/pdfcpu/cmd/pdfcpu@$PDFCPU_VER" >/dev/null
for arch in arm64 amd64; do
  CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags="-s -w" -o "pdfcpu-$arch" github.com/pdfcpu/pdfcpu/cmd/pdfcpu
done
lipo -create pdfcpu-arm64 pdfcpu-amd64 -output "$OUT/pdfcpu"
lipo -info "$OUT/pdfcpu"
"$OUT/pdfcpu" version | head -1
cd "$WORK"
echo "=== qpdf $QPDF_VER (statik, native crypto, universal) ==="
[ -d "qpdf-$QPDF_VER" ] || curl -fsSL "https://github.com/qpdf/qpdf/releases/download/v$QPDF_VER/qpdf-$QPDF_VER.tar.gz" | tar xz
rm -rf qpdf-build  # pkg-config sonucu cache'e yazılır; her seferinde temiz yapılandır
# qpdf libjpeg'i pkg-config ile arar (JPEG_LIBRARY/JPEG_INCLUDE_DIR qpdf CMake'inde tanınmıyor —
# unused-cli uyarısı verir, qpdf'in kendi bulma mekanizması yalnızca pkg-config/find_library'dir).
# PKG_CONFIG_LIBDIR brew'in Intel dylib'i yerine bizim statik fat libjpeg.pc'mizin bulunmasını sağlar.
PKG_CONFIG_LIBDIR="$WORK/prefix/lib/pkgconfig" \
cmake -S "qpdf-$QPDF_VER" -B qpdf-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_DOC=OFF -DBUILD_TESTING=OFF \
  -DREQUIRE_CRYPTO_NATIVE=ON -DUSE_IMPLICIT_CRYPTO=OFF \
  -DCMAKE_PREFIX_PATH="$WORK/prefix" -DZLIB_ROOT="$(xcrun --show-sdk-path)/usr" >/dev/null
cmake --build qpdf-build -j"$(sysctl -n hw.ncpu)" --target qpdf >/dev/null
cp qpdf-build/qpdf/qpdf "$OUT/qpdf"
strip "$OUT/qpdf"
lipo -info "$OUT/qpdf"
otool -L "$OUT/qpdf"
"$OUT/qpdf" --version | head -1

echo "=== lisanslar ==="
# Apache-2.0 ve IJG/BSD yükümlülüğü: dağıtılan ikililerin lisans metinleri pakete girer.
LIC="$ROOT/vendor/licenses"
mkdir -p "$LIC"
# install kullanılır, cp değil: Go modül önbelleğindeki dosyalar 0444'tür ve düz cp
# ikinci çalıştırmada "Permission denied" ile SESSİZCE düşer (ölçüldü, 2026-09-07).
install -m 644 "$WORK/qpdf-$QPDF_VER/LICENSE.txt" "$LIC/qpdf-LICENSE.txt"
install -m 644 "$WORK/qpdf-$QPDF_VER/NOTICE.md" "$LIC/qpdf-NOTICE.md"
install -m 644 "$WORK/libjpeg-turbo-$JPEG_VER/LICENSE.md" "$LIC/libjpeg-turbo-LICENSE.md"
PDFCPU_LIC="$(find "$(go env GOMODCACHE)/github.com/pdfcpu" -maxdepth 2 -iname 'LICENSE*' | sort | tail -1)"
if [ -z "$PDFCPU_LIC" ]; then
  echo "HATA: pdfcpu lisansı bulunamadı — Apache-2.0 dağıtım yükümlülüğü karşılanamaz" >&2
  exit 1
fi
install -m 644 "$PDFCPU_LIC" "$LIC/pdfcpu-LICENSE.txt"
ls -l "$LIC"

echo "=== bitti: $(ls -la "$OUT")"
