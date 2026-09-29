import XCTest

@testable import PDFToolsCore

/// Motor argümanı kurma kurallarını PLATFORMDAN BAĞIMSIZ çiviler.
///
/// NEDEN AYRI BİR DOSYA (2026-09-29): aynı korumanın uçtan uca testleri (`DashFilenameSafetyTests`)
/// `-` ile başlayan GÖRELİ bir `file:` URL'i kurmak zorunda ve bunun `path` davranışı Foundation
/// sürümüne göre değişiyor — yerelde "-bare.pdf", CI'ın macOS 15 çalıştırıcısında "" (ölçüldü:
/// CI'da o testler ürün kodunu değil kendi kurgusunu düşürdü). Uçtan uca testler o platformda
/// artık ATLANIYOR; koruma mantığının kendisi burada dizge düzeyinde, her yerde aynı çalışan
/// testlerle korunuyor. Ders: taşınabilir olmayan bir kurgunun üstüne kurulmuş kapı, kapı değildir.
final class EngineArgumentTests: XCTestCase {
  /// qpdf'te `--` tekil komutlarda İŞE YARAMIYOR (ölçüldü) — koruma `./` ön eki.
  func testQPDFArgumentPrefixesDashLeadingPaths() {
    XCTAssertEqual(QPDFArgument.path(for: "-bare.pdf"), "./-bare.pdf")
    XCTAssertEqual(QPDFArgument.path(for: "--replace-input.pdf"), "./--replace-input.pdf")
    XCTAssertEqual(QPDFArgument.path(for: "-"), "./-")
  }

  /// Zararsız yollar DEĞİŞMEDEN geçer — koruma davranışı bozmuyor.
  func testQPDFArgumentLeavesNormalPathsUntouched() {
    XCTAssertEqual(QPDFArgument.path(for: "/Users/x/kitap.pdf"), "/Users/x/kitap.pdf")
    XCTAssertEqual(QPDFArgument.path(for: "kitap.pdf"), "kitap.pdf")
    XCTAssertEqual(QPDFArgument.path(for: "./kitap.pdf"), "./kitap.pdf")
    XCTAssertEqual(QPDFArgument.path(for: "kitap-2026.pdf"), "kitap-2026.pdf")
  }

  /// Mutlak `URL` aşırı yüklemesi dizge aşırı yüklemesiyle AYNI sonucu verir (çağıranlar bunu
  /// kullanıyor; iki yolun ayrışması sessiz bir kör nokta olurdu).
  func testQPDFArgumentURLOverloadMatchesStringOverload() {
    let url = URL(fileURLWithPath: "/tmp/pdftools-engine-args.pdf")
    XCTAssertEqual(QPDFArgument.path(for: url), QPDFArgument.path(for: url.path))
    XCTAssertEqual(QPDFArgument.path(for: url), "/tmp/pdftools-engine-args.pdf")
  }

  /// pdfcpu'nun küresel config'i okumasını kapatan bayrak çifti — sıra ve yazım önemli, çünkü
  /// v0.16.0 eski şemalı config'i görünce HER komutu reddediyor (ölçüldü).
  func testPDFCPUDisableConfigFlagIsExact() {
    XCTAssertEqual(PDFCPUArgument.disableConfig, ["--conf", "disable"])
  }
}
