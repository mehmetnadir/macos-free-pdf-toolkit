import XCTest

@testable import PDFToolsCore

/// Genel ilerleme matematiği. Yanlış hesap sessizdir: kullanıcı "%80"de duran ya da bitmeden
/// dolan bir çubuk görür, hiçbir test kırılmaz. Bu yüzden sınırlar tek tek çivileniyor.
final class BatchProgressTests: XCTestCase {
  func testNoFilesIsZero() {
    XCTAssertEqual(BatchProgressMath.fraction(completed: 0, inFlight: [], total: 0), 0)
  }

  /// `total == 0` koruması olmadan bu hesap 1/0 = +sonsuz üretir ve çubuk dolu görünür.
  /// (Yalnız `completed: 0` ile sınamak YETMEZ: orada 0/0 = NaN çıkıyor ve kırpma onu
  /// tesadüfen 0'a çeviriyor, yani koruma kaldırılsa bile test yeşil kalıyordu — ölçüldü.)
  func testZeroTotalCannotFillTheBar() {
    XCTAssertEqual(BatchProgressMath.fraction(completed: 1, inFlight: [], total: 0), 0)
  }

  func testNothingStartedIsZero() {
    XCTAssertEqual(BatchProgressMath.fraction(completed: 0, inFlight: [], total: 4), 0)
  }

  func testCompletedFilesCount() {
    XCTAssertEqual(BatchProgressMath.fraction(completed: 2, inFlight: [], total: 4), 0.5)
  }

  func testRunningFileContributesItsFraction() {
    // 2 bitti + 1 dosya yarısında, toplam 4 → (2 + 0.5) / 4
    XCTAssertEqual(BatchProgressMath.fraction(completed: 2, inFlight: [0.5], total: 4), 0.625)
  }

  func testAllDoneIsExactlyOne() {
    XCTAssertEqual(BatchProgressMath.fraction(completed: 4, inFlight: [], total: 4), 1)
  }

  /// Birleştir kipi: TÜM dosyalar aynı anda aynı kesirle çalışır. Kesirler ayrı ayrı geçmeli;
  /// önceden toplanıp tek değer olarak geçilirse (ilk yazımda öyleydi) kırpma yüzünden
  /// %20'lik bir ilerleme %100 görünürdü.
  func testCombinedModeReportsTheSharedFraction() {
    let value = BatchProgressMath.fraction(completed: 0, inFlight: [0.2, 0.2, 0.2, 0.2], total: 4)
    XCTAssertEqual(value, 0.2, accuracy: 0.0001)
  }

  /// Motor 1.0'ı aşan bir kesir bildirirse çubuk taşmamalı.
  func testFractionNeverExceedsOne() {
    XCTAssertEqual(BatchProgressMath.fraction(completed: 3, inFlight: [5.0], total: 3), 1)
  }

  func testNegativeEngineNoiseIsIgnored() {
    XCTAssertEqual(BatchProgressMath.fraction(completed: 1, inFlight: [-0.5], total: 2), 0.5)
  }
}
