import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// Tur 3'ün eylem kartları için `OperationApplicability` + `OperationRegistry.suggested(for:)`
/// testleri. Yalnız METAVERİYE bakan saf mantık test ediliyor — gerçek PDF dosyası/disk erişimi
/// gerekmez, `PDFFileInfo` doğrudan (var olmayan bir) URL ile kurulur. Tek istisna: Kesim Payını
/// At'ın motor kontrolü — gs kuruluysa test edilir, değilse `XCTSkip` (bkz. `TrimTests` ile aynı
/// desen, `.claude/CLAUDE.md`).
final class ApplicabilityTests: XCTestCase {
  private func dummyFile(
    pageCount: Int = 3, lockState: PDFLockState = .none,
    mediaBox: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200), trimBox: CGRect? = nil,
    name: String = "dummy.pdf"
  ) -> PDFFileInfo {
    PDFFileInfo(
      url: URL(fileURLWithPath: "/tmp/pdftools-applicability-\(name)"),
      fileSize: 1024, pageCount: pageCount, lockState: lockState, mediaBox: mediaBox, trimBox: trimBox)
  }

  // MARK: - 1. Kilit Aç

  func testUnlockNotApplicableWhenAllUnencrypted() {
    let files = [dummyFile(lockState: .none), dummyFile(lockState: .none)]
    XCTAssertEqual(
      UnlockOperation().applicability(for: files),
      .notApplicable(reason: "Files are already unlocked"))
  }

  func testUnlockApplicableCountsOnlyLockedFiles() {
    let files = [
      dummyFile(lockState: .none), dummyFile(lockState: .restricted),
      dummyFile(lockState: .passwordRequired),
    ]
    XCTAssertEqual(UnlockOperation().applicability(for: files), .applicable(fileCount: 2))
  }

  // MARK: - 2. Kesim Payını At

  func testTrimNotApplicableWhenNoBleed() {
    let files = [dummyFile(trimBox: nil)]
    // Motor kurulu olsa da olmasa da: kesim payı hiç yoksa mesaj HEP "No bleed margin found" olmalı
    // (bkz. TrimOperation.applicability yorumu — sıra bilerek böyle, CI'da gs olmadan da geçerli).
    XCTAssertEqual(
      TrimOperation().applicability(for: files), .notApplicable(reason: "No bleed margin found"))
  }

  func testTrimApplicableWhenBleedPresentAndEngineInstalled() throws {
    try XCTSkipUnless(EngineLocator.trimEngine() != nil, "gs kurulu değil, atlanıyor")
    let bleeding = dummyFile(
      mediaBox: CGRect(x: 0, y: 0, width: 200, height: 200),
      trimBox: CGRect(x: 10, y: 10, width: 180, height: 180), name: "bleed.pdf")
    let clean = dummyFile(trimBox: nil, name: "clean.pdf")
    XCTAssertEqual(TrimOperation().applicability(for: [bleeding, clean]), .applicable(fileCount: 1))
  }

  // MARK: - 3. Birleştir

  func testMergeNotApplicableWithSingleFile() {
    XCTAssertEqual(
      MergeOperation().applicability(for: [dummyFile()]),
      .notApplicable(reason: "Needs at least two files to merge"))
  }

  func testMergeApplicableWithTwoFiles() {
    let files = [dummyFile(name: "a.pdf"), dummyFile(name: "b.pdf")]
    XCTAssertEqual(MergeOperation().applicability(for: files), .applicable(fileCount: 2))
  }

  // MARK: - 4. Parçala

  func testSplitNotApplicableWithSinglePageFile() {
    XCTAssertEqual(
      SplitOperation().applicability(for: [dummyFile(pageCount: 1)]),
      .notApplicable(reason: "Needs at least two pages to split"))
  }

  func testSplitApplicableWithMultiPageFile() {
    XCTAssertEqual(
      SplitOperation().applicability(for: [dummyFile(pageCount: 5)]), .applicable(fileCount: 1))
  }

  // MARK: - 5. Boş liste

  func testAllOperationsNotApplicableWhenListEmpty() {
    for operation in OperationRegistry.all {
      guard case .notApplicable(let reason) = operation.applicability(for: []) else {
        return XCTFail("\(operation.title) boş listede applicable döndü")
      }
      XCTAssertEqual(reason, "Add a PDF first", "\(operation.title) için beklenmeyen gerekçe")
    }
    XCTAssertNil(OperationRegistry.suggested(for: []))
  }

  // MARK: - 6. Öne çıkan eylem (mutasyon kanıtı raporda anlatılıyor)

  /// Sıra: kilitli > kesim paylı > 2+ dosya (Birleştir) > aksi halde Sayfa Düzenle.
  func testSuggestedOperationPriorityOrder() {
    let locked = dummyFile(lockState: .passwordRequired, name: "locked.pdf")
    let bleeding = dummyFile(
      trimBox: CGRect(x: 10, y: 10, width: 180, height: 180), name: "bleed.pdf")
    let plain = dummyFile(name: "plain.pdf")
    let plain2 = dummyFile(name: "plain2.pdf")

    // Kilitli + kesim paylı karışık liste → kilitli KAZANIR.
    XCTAssertEqual(
      OperationRegistry.suggested(for: [bleeding, locked])?.id, UnlockOperation.identifier)
    // Kilitli yok, kesim paylı var → Kesim Payını At.
    XCTAssertEqual(
      OperationRegistry.suggested(for: [plain, bleeding])?.id, TrimOperation.identifier)
    // Kilitli/kesim payı yok, 2+ dosya → Birleştir.
    XCTAssertEqual(OperationRegistry.suggested(for: [plain, plain2])?.id, MergeOperation.identifier)
    // Kilitli/kesim payı yok, tek dosya → Sayfa Düzenle.
    XCTAssertEqual(OperationRegistry.suggested(for: [plain])?.id, PageEditOperation.identifier)
  }
}
