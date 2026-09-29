import XCTest

@testable import PDFToolsCore

/// `OCROperation.combine`/`unopenedPagesNote` saf fonksiyon testleri — hiçbir PDF/Vision GEREKMEZ,
/// bir sayfanın `document.page(at:)`den `nil` dönmesini doğrudan sözlükte "anahtar eksik" olarak
/// ENJEKTE EDER (bkz. `run()`'daki gerçek döngü).
///
/// NEDEN VAR (2026-09-29 sessiz-hata denetimi, bulgu 1). Eski `combine(_ pageTexts: [String])`
/// SIRALI bir diziydi: bir sayfa açılamayıp `continue` ile atlandığında dizi DELİK BIRAKMIYORDU,
/// bu yüzden atlanan sayfadan SONRAKİ TÜM sayfalar `combine`in `index + 1` varsayımıyla bir numara
/// KÜÇÜK etiketleniyordu (`--- page N ---` ayracı yanlış sayfayı gösteriyordu) — hiçbir kapı bunu
/// yakalamıyordu (`confidences.isEmpty` yalnız HİÇ metin tanınmadıysa tetiklenir). Düzeltme: girdi
/// artık `[Int: String]` (sayfa numarasından metne), `combine` `1...total` üzerinde döner ve eksik
/// anahtarı boş metinle (numara KAYMADAN) doldurur.
final class OCRCombineTests: XCTestCase {

  /// ASIL REGRESYON TESTİ: sayfa 2 açılamadı (sözlükte anahtarı YOK) — sayfa 3'ün metni GERÇEK
  /// numarasıyla ("page 3") basılmalı, "page 2" ile DEĞİL. Mutasyon kanıtı (elle koşuldu, görev
  /// raporunda belgelendi): `combine`in imzası eski `[String]` haline geçici geri alınıp bu test
  /// çalıştırıldığında KIRMIZI verdi (sayfa 3'ün metni "page 2" ayracının altında çıktı), düzeltme
  /// geri konunca YEŞİLE döndü.
  func testSkippedPageDoesNotShiftSubsequentPageNumbers() {
    let pages: [Int: String] = [1: "birinci", 3: "ucuncu"]
    let combined = OCROperation.combine(pages, total: 3)
    let expected = "--- page 1 ---\nbirinci\n\n--- page 2 ---\n\n\n--- page 3 ---\nucuncu"
    XCTAssertEqual(combined, expected)
  }

  /// Hiç sayfa atlanmadıysa davranış eskisiyle AYNI: her sayfa kendi numarasıyla, sırayla.
  func testAllPagesPresentProducesSequentialSeparators() {
    let pages: [Int: String] = [1: "bir", 2: "iki", 3: "uc"]
    let combined = OCROperation.combine(pages, total: 3)
    XCTAssertEqual(combined, "--- page 1 ---\nbir\n\n--- page 2 ---\niki\n\n--- page 3 ---\nuc")
  }

  func testEmptyTotalProducesEmptyString() {
    XCTAssertEqual(OCROperation.combine([:], total: 0), "")
  }

  /// BELGESEL TEST (üretim kodunu ÇAĞIRMAZ) — eski hatanın MEKANİZMASINI gösterir: sıralı bir
  /// dizi kullanılsaydı (eski imza), atlanan sayfa dizide delik bırakmadığı için sayfa 3'ün metni
  /// "page 2" ayracının altına düşerdi. Yeni `combine(_:total:)` bunu yapısal olarak İMKÂNSIZ
  /// kılıyor (bkz. üstteki `testSkippedPageDoesNotShiftSubsequentPageNumbers`).
  func testOldArrayBasedApproachWouldHaveShiftedPageNumbers() {
    var oldStyleBlocks: [String] = []
    let simulatedPages: [Int: String] = [1: "birinci", 3: "ucuncu"]
    for pageIndex in 1...3 where simulatedPages[pageIndex] != nil {
      oldStyleBlocks.append(simulatedPages[pageIndex]!)
    }
    let oldCombined = oldStyleBlocks.enumerated()
      .map { "--- page \($0.offset + 1) ---\n\($0.element)" }
      .joined(separator: "\n\n")
    XCTAssertTrue(
      oldCombined.contains("--- page 2 ---\nucuncu"),
      "eski mekanizma yeniden üretilemedi, karşılaştırma geçersiz: \(oldCombined)")
    XCTAssertFalse(
      oldCombined.contains("--- page 3 ---"),
      "eski yöntemde 3. sayfanın GERÇEK numarası hiç görünmüyordu: \(oldCombined)")
  }

  // MARK: - unopenedPagesNote

  func testUnopenedPagesNoteIsNilWhenNoPageWasSkipped() {
    XCTAssertNil(OCROperation.unopenedPagesNote([]))
  }

  /// Sessizce yutulmuyor: atlanan sayfalar SIRALI ve okunur biçimde bildiriliyor.
  func testUnopenedPagesNoteListsSkippedPagesInOrder() {
    let note = OCROperation.unopenedPagesNote([5, 2])
    XCTAssertEqual(
      note,
      "Page(s) 2, 5 could not be opened and were skipped — page numbers for the "
        + "remaining pages are unaffected.")
  }
}
