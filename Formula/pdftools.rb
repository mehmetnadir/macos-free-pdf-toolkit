# `pdftools` CLI formülü — KAYNAKTAN DERLEMEZ, yayındaki hazır evrensel ikiliyi kurar.
#
# Neden kaynaktan derlemiyoruz: Homebrew derlemeyi ağ ERİŞİMİ OLMADAN koşar, SwiftPM ise
# manifesti çözmek için Sparkle paketini indirmek zorunda (Sparkle paket düzeyinde bir
# bağımlılık; yalnız `--product pdftools` derlense bile çözümleme yapılır). Yani kaynak
# derlemesi Homebrew ortamında güvenilir biçimde çalışmaz. Yayın betiği (packaging/release.sh)
# bu yüzden evrensel (arm64+x86_64) `pdftools` ikilisini ayrı bir varlık olarak yükler.
#
# Motorlar (qpdf/pdfcpu) neden Homebrew'dan: `Sources/PDFToolsCore/Engines/EngineLocator.swift`
# Release derlemesinde Homebrew yollarını BİLEREK aramaz — kullanıcı parolası motora argümanla
# geçtiğinden yalnız uygulama paketindeki ikiliye güvenilir (dosyadaki gerekçe notu). CLI
# kurulumunda paket yoktur; bu yüzden kodu gevşetmek YERİNE, sarmalayıcı betik
# `PDFTOOLS_BIN_DIR`ı Homebrew'un bin dizinine sabitler (bu değişken Release'de de okunur).
class Pdftools < Formula
  desc "Free, local, native macOS PDF toolkit (command-line)"
  homepage "https://github.com/mehmetnadir/macos-free-pdf-toolkit"
  url "https://github.com/mehmetnadir/macos-free-pdf-toolkit/releases/download/v0.1.0/pdftools-0.1.0-universal.tar.gz"
  version "0.1.0"
  # NOT: henüz yayın yapılmadı. packaging/release.sh (RELEASE_CONFIRM=1) bu alanı
  # yükledikten sonra kendisi günceller; elle doldurmak için:
  #   shasum -a 256 build/pdftools-<sürüm>-universal.tar.gz
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on macos: :sonoma
  depends_on "pdfcpu"
  depends_on "qpdf"

  def install
    libexec.install "pdftools"
    # Sarmalayıcı: motor arama dizinini açıkça Homebrew prefix'ine sabitler.
    (bin/"pdftools").write_env_script libexec/"pdftools",
                                      PDFTOOLS_BIN_DIR: "#{HOMEBREW_PREFIX}/bin"
  end

  def caveats
    <<~EOS
      Compress "strong" seviyesi Ghostscript ister (AGPL olduğu için pakete gömülmez):
        brew install ghostscript
      Diğer bütün işlemler qpdf/pdfcpu ve macOS çatılarıyla çalışır.
    EOS
  end

  test do
    # Gerçek çalıştırma: sarmalayıcı motorları bulabiliyor mu?
    output = shell_output("#{bin}/pdftools engines")
    assert_match "qpdf", output
    assert_match "pdfcpu", output
  end
end
