[English](README.md)

# PDF Araçları

[![CI](https://github.com/mehmetnadir/macos-free-pdf-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/mehmetnadir/macos-free-pdf-toolkit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

Ücretsiz, yerel, gerçek bir macOS PDF araç kutusu — yükleme yok, abonelik yok.

![PDF Araçları](docs/screenshot.png)

## Özellikler

- **Kilit Aç** — şifreli PDF'lerin sahip/kullanıcı parolasını ve kısıtlamalarını, tamamen cihaz üzerinde kaldırır.
- **Kesim Payını At** — matbaa kesim/taşma payını (TrimBox) kalıcı olarak siler, tamamen cihaz üzerinde. Ayrıca kurulu Ghostscript gerektirir (`brew install ghostscript`) — pakete neden gömülmediği için [Motor Karşılaştırması](#motor-karşılaştırması) bölümüne bak.

Proje erken aşamada ve henüz yapılmamış olanı saklamıyor — sırada ne olduğu için [Yol Haritası](#yol-haritası)'na bak.

## Kurulum

[Releases](../../releases)'tan son DMG'yi indir, aç, **PDF Araçları.app**'i Uygulamalar'a sürükle. Uygulama henüz notarize edilmedi; ilk açılışta sağ tık → Aç. Kendin derlemek istersen: [Kaynaktan Derleme](#kaynaktan-derleme).

## Kullanım

### GUI
`PDF Araçları.app`'i aç, PDF dosyalarını (veya bir klasörü) pencereye sürükle-bırak, işlemi seç (dosya gerektiriyorsa şifreyi gir), çalıştır. Sonuç listesi dosya başına tamam/atlandı/hata gösterir; oradan çıktıyı Finder'da açabilirsin.

### CLI
```bash
swift run pdftools engines
swift run pdftools unlock [--password ŞİFRE] [--out KLASÖR] dosya.pdf...
swift run pdftools trim [--out KLASÖR] dosya.pdf...
```

## Motor Karşılaştırması

Ölçüm 2026-09-07, Apple Silicon, 593 MB / 144 sayfa, AES-128 sahip-şifreli bir PDF'in kilidini açarken:

| Motor | Süre | Sonuç |
|---|---|---|
| qpdf | 3,1 sn | Başarılı — PDF sürümü ve metadata korunur. **Birincil motor.** |
| pdfcpu | 5,9 sn | Başarılı — Producer/CreationDate'i ezer, PDF sürümünü 1.7'ye çıkarır. **Yedek motor.** |
| pypdf | 1,6 sn | Başarılı ama Python çalışma zamanı gerektirir — elendi. |
| Apple PDFKit (yerleşik) | 28 sn | Çıktı **hâlâ şifreli** kaldı — elendi. |
| fadeltd/pdfunlock (Go) | — | TTY'den şifre istiyor, boş şifreyi hiç denemiyor, uygulamadan tetiklenemiyor — elendi. |

qpdf ve pdfcpu, `packaging/build-engines.sh` ile universal (arm64+x86_64) statik ikili olarak derlenir ve uygulama paketinin içinde taşınır — kilit açma sırasında çalışma zamanı bağımlılığı ya da ağ çağrısı yoktur.

**Kesim Payını At** Ghostscript kullanır (`gs -dUseTrimBox -sDEVICE=pdfwrite`) ve **pakete gömülmez, gömülmeyecek**: Ghostscript AGPL-3.0-or-later, bu proje ise MIT ve yukarıdaki iki motor Apache-2.0. AGPL bir ikiliyi gömmek tüm dağıtımı AGPL kapsamına çeker. Bunun yerine yalnızca kullanıcının zaten kurduğu `gs` aranır (Homebrew); bulunamazsa özellik sessizce başarısız olmak yerine kurulum ipucuyla nazikçe devre dışı kalır. Ölçülmüş bir sınır: Ghostscript'in kesimi içeriği yalnızca yeni sayfa köküne göre KAYDIRIR, eski kesim sınırını aşan geometriyi (ör. tam sayfa taşan bir görsel ya da sayfayı boydan boya kesen bir kılavuz çizgisi) kırpmaz — bu yüzden uygulama her kesim çıktısını, bildirilen sayfa kutusunun dışına taşarak render edip kalıntı mürekkep var mı diye denetler; kutu üstverisine güvenmek yerine bunu reddeder (ya da işaretler).

## Yol Haritası

- **v0.2** — Birleştir, Parçala, sayfa sırala/döndür/sil, Filigran kaldır, PDF → görüntü (PNG/JPEG/HEIC/WebP)
- **v0.3** — Sıkıştır, filigran/sayfa numarası ekle, Şifrele, QR ekle/ayıkla
- **v0.4** — Lineerleştir, onar/doğrula, görsel çıkar, yer imi düzenle, metin/metadata çıkar
- **v1.0** — Derin OCR (düzen ve formül farkında, OmniDocBench ile ölçülecek)

## Kaynaktan Derleme

Gereksinimler: macOS 14+, Xcode 26 / Swift 6.3. Motor derlemesi için ek olarak `cmake`, `go`, `gh` gerekir.

```bash
./packaging/build-engines.sh   # qpdf + pdfcpu'yu vendor/bin/'e derler (internet gerekir, tekrarlanabilir)
swift build                    # universal derleme: swift build --arch arm64 --arch x86_64
swift test                     # 16 test, Tests/PDFToolsCoreTests/ (gs kurulu değilse kesim testleri atlanır)
./packaging/build.sh           # build/PDF Araçları.app üretir (Developer ID imza için SIGN_IDENTITY env)
```

Harici SwiftPM bağımlılığı yok. Projedeki tek üçüncü taraf kod, aşağıda anlatılan iki gömülü motor ikilisidir.

## Üçüncü Taraf Bileşenler

qpdf ve pdfcpu, uygulama paketinin içinde derlenmiş ikili olarak taşınır (qpdf, libjpeg-turbo'yu statik linkler). Tam bileşen listesi, sürümler, kaynak adresleri ve lisans metinleri: [THIRD_PARTY.md](THIRD_PARTY.md).

## Lisans

MIT — bkz. [LICENSE](LICENSE).
