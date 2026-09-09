import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// `CoreGraphicsTrimEngine` testleri — `TrimTests.swift`'ten BİLEREK AYRI dosya (kapsam: yalnız
/// CoreGraphics motoru, `EngineLocator.trimEngine()` seçimi ve döndürme davranışı; gs'e özgü
/// testlere DOKUNULMADI). Fixture'lar `TrimTests` ile AYNI teknikle CoreGraphics'le programatik
/// üretilir — repoya gerçek/telifli matbaa dosyası eklenmez.
///
/// Döndürmeli fixture NASIL üretiliyor: `CGPDFContext`'in sayfa sözlüğü (`beginPDFPage` pageInfo)
/// yalnızca MediaBox/CropBox/BleedBox/TrimBox/ArtBox anahtarlarını kabul eder — `/Rotate` YAZILAMAZ
/// (`CGPDFContext.h` kontrol edildi, bkz. `CoreGraphicsTrimEngine.swift` dosya üstü notu). Bu yüzden
/// önce rotasyonsuz bir fixture üretilip `PageEditOperation` (qpdf `--rotate`, mutlak) ile
/// döndürülüyor — `PageEditTests.swift`'teki AYNI desen. qpdf'in `--rotate`'i yalnız `/Rotate`
/// bayrağını yazar, TrimBox'a ya da içerik akışına DOKUNMAZ (ölçüldü, bkz.
/// `PageEditVerification.swift` dosya üstü notu) — bu yüzden rotasyon öncesi çizilen TrimBox/marker
/// koordinatları rotasyon sonrası da AYNI kalır.
final class CGTrimTests: XCTestCase {
  // Döndürme testi qpdf gerektiriyor (`PageEditOperation`); `xctest` çalıştırıcısı altında
  // `Bundle.main` gerçek vendor/bin yolunu vermediğinden `PageEditTests`/`Tur1Tests` ile AYNI
  // desen: kökten `vendor/bin`'i elle ekle.
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override class func setUp() {
    super.setUp()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-cgtrim-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - Fixture üreticileri

  /// Tek sayfalık, isteğe bağlı TrimBox'lı bir PDF yazar; sayfa içeriği `draw` kapanışına bırakılır.
  private static func makeFixture(
    mediaBox: CGRect, trimBox: CGRect?, to url: URL, draw: @escaping (CGContext) -> Void
  ) {
    makeMultiPageFixture(mediaBox: mediaBox, trimBoxes: [trimBox], draws: [draw], to: url)
  }

  /// Çok sayfalı, sayfa başına FARKLI TrimBox'lı bir PDF yazar (`trimBoxes`/`draws` aynı uzunlukta
  /// olmalı — sayfa sırasıyla eşlenir).
  private static func makeMultiPageFixture(
    mediaBox: CGRect, trimBoxes: [CGRect?], draws: [(CGContext) -> Void], to url: URL
  ) {
    precondition(trimBoxes.count == draws.count, "trimBoxes/draws uzunluğu eşleşmeli")
    try? FileManager.default.removeItem(at: url)
    var box = mediaBox
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    for (index, trim) in trimBoxes.enumerated() {
      var pageInfo: [CFString: Any] = [:]
      if var t = trim {
        let data = Data(bytes: &t, count: MemoryLayout<CGRect>.size)
        pageInfo[kCGPDFContextTrimBox] = data as CFData
      }
      context.beginPDFPage(pageInfo as CFDictionary)
      draws[index](context)
      context.endPDFPage()
    }
    context.closePDF()
  }

  /// `source`'un 1. sayfasını (mutlak) `degrees`'e döndürüp yeni bir dosya üretir — `PageEditTests`
  /// ile aynı `PageEditOperation` çağrısı, yalnız tek dosyada.
  private func rotateFirstPage(of source: URL, degrees: Int, dir: URL) async throws -> URL {
    let context = OperationContext(
      outputDirectory: dir, options: [PageEditOperation.rotationsOptionID: "1:\(degrees)"])
    let outcome = try await PageEditOperation().run(
      file: PDFFileInfo.inspect(source), context: context) { _ in }
    guard case .produced(let outputs, _) = outcome, let output = outputs.first else {
      XCTFail("döndürme fixture'ı üretilemedi: \(outcome)")
      throw XCTSkip("qpdf ile döndürme fixture'ı üretilemedi")
    }
    return output
  }

  private func runTrim(input: URL, dir: URL) async throws -> URL {
    let output = dir.appendingPathComponent(
      input.deletingPathExtension().lastPathComponent + "_cgtrimmed.pdf")
    try await CoreGraphicsTrimEngine().trim(input: input, output: output) { _ in }
    return output
  }

  // MARK: - Ölçüm yardımcıları

  /// `TrimVerification.verify`'la AYNI yöntem (bkz. o dosyanın üst yorumu): çıktının KENDİ
  /// bildirdiği kutusunu her yönde `pad` genişletip render eder, eski sınırın DIŞINDA kalan
  /// banttaki beyaz-olmayan piksel oranını döndürür. Burada BİLEREK ayrı/parametrik yazıldı —
  /// `pad` testteki geometriyle (TrimBox'ın MediaBox'a göre içeri çekilme miktarı) TAM eşleşsin
  /// diye; `TrimVerification`'ın sabit 8,5pt'i bu testin amacı için gerekli değil.
  private static func residuePercent(of url: URL, pad: CGFloat, dpi: CGFloat = 150) -> Double {
    guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return 100 }
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return 100 }
    let expanded = box.insetBy(dx: -pad, dy: -pad)
    let scale = dpi / 72
    let w = max(1, Int((expanded.width * scale).rounded(.up)))
    let h = max(1, Int((expanded.height * scale).rounded(.up)))
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return 100 }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -expanded.origin.x, y: -expanded.origin.y)
    // `drawPDFPage` kutuya göre KIRPMAZ (bkz. TrimVerification notu) — kaçan içerik varsa görünür.
    ctx.drawPDFPage(page)
    guard let data = ctx.data else { return 100 }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * h)
    var band = 0
    var ink = 0
    for row in 0..<h {
      let userY = expanded.maxY - (Double(row) + 0.5) / Double(scale)
      let rowStart = row * bytesPerRow
      for col in 0..<w {
        let userX = expanded.origin.x + (Double(col) + 0.5) / Double(scale)
        guard !box.contains(CGPoint(x: userX, y: userY)) else { continue }
        band += 1
        if buffer[rowStart + col] < 245 { ink += 1 }
      }
    }
    return band == 0 ? 0 : Double(ink) / Double(band) * 100
  }

  /// `url`'in ilk sayfasını (rotasyon UYGULAMADAN — çıktı sayfalarının zaten `/Rotate`'i yok, bkz.
  /// dosya üstü notu) 1pt=1px ölçeğinde RGB render eder, sayfa-uzayı `region`'daki (punto)
  /// piksellerin ortalama rengini (0...1) döndürür. Rotasyon/köşe testlerinde "bu bölgede marker
  /// rengi var mı" sorusuna cevap vermek için kullanılıyor.
  private static func averageColor(of url: URL, region: CGRect) -> (r: Double, g: Double, b: Double)? {
    guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
    let box = page.getBoxRect(.mediaBox)
    let w = max(1, Int(box.width.rounded()))
    let h = max(1, Int(box.height.rounded()))
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let data = ctx.data else { return nil }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * h)

    let clipped = region.intersection(box)
    guard !clipped.isEmpty else { return nil }
    let minCol = max(0, Int((clipped.minX - box.minX).rounded(.down)))
    let maxCol = min(w - 1, Int((clipped.maxX - box.minX).rounded(.up)) - 1)
    let minRow = max(0, Int((box.maxY - clipped.maxY).rounded(.down)))
    let maxRow = min(h - 1, Int((box.maxY - clipped.minY).rounded(.up)) - 1)
    guard minCol <= maxCol, minRow <= maxRow else { return nil }

    var sumR = 0.0, sumG = 0.0, sumB = 0.0, count = 0.0
    for row in minRow...maxRow {
      let rowStart = row * bytesPerRow
      for col in minCol...maxCol {
        let o = rowStart + col * 4
        sumR += Double(buffer[o])
        sumG += Double(buffer[o + 1])
        sumB += Double(buffer[o + 2])
        count += 1
      }
    }
    guard count > 0 else { return nil }
    return (sumR / count / 255, sumG / count / 255, sumB / count / 255)
  }

  // MARK: - 1. Kırpma bandı sızıntısını gerçekten siliyor mu (testin kalbi)

  func testClipRemovesBleedFromMarginBand() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("bleed-source.pdf")
    let mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
    let trimBox = CGRect(x: 20, y: 20, width: 160, height: 160)
    Self.makeFixture(mediaBox: mediaBox, trimBox: trimBox, to: source) { ctx in
      // Kenar bandı (mediaBox − trimBox) KOYU: kırpma çalışmazsa bu banda sızar.
      ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      ctx.fill(mediaBox)
      // TrimBox içi temiz beyaz zemin.
      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      ctx.fill(trimBox)
      // Ortada belirgin bir şekil ("sayfa içeriği" sayılan blok).
      ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
      ctx.fill(trimBox.insetBy(dx: 60, dy: 60))
    }

    let output = try await runTrim(input: source, dir: dir)
    guard let doc = CGPDFDocument(output as CFURL), let page = doc.page(at: 1) else {
      return XCTFail("çıktı açılamadı")
    }
    let outputBox = page.getBoxRect(.mediaBox)
    XCTAssertEqual(outputBox.width, trimBox.width, accuracy: 0.5)
    XCTAssertEqual(outputBox.height, trimBox.height, accuracy: 0.5)

    // `pad` BİLEREK bandın kendi genişliğiyle (20pt) aynı — tam bandı örnekler.
    let residue = Self.residuePercent(of: output, pad: 20)
    // Eşik `TrimVerification.cleanThreshold` (%2,0) ile AYNI — sıfır DEĞİL: ölçüldü (scratchpad
    // probe5, 2026-09-09), kalan tüm mürekkep pikselleri sınırdan TAM 0pt mesafede (yalnızca kırpma
    // hattındaki kaçınılmaz vektör-antialiasing), bandın içine hiç sızmıyor — bu projenin kendi
    // "temiz" tanımıyla tutarlı gerçek bir kırpma başarısı, kalıntı bir sızıntı değil.
    XCTAssertLessThan(
      residue, 2.0, "kırpma kenar bandındaki koyu dolguyu silmemiş görünüyor, kalıntı %\(residue)")
  }

  // MARK: - 2. Sayfa sayısı korunuyor mu

  func testPageCountPreserved() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("multipage.pdf")
    let mediaBox = CGRect(x: 0, y: 0, width: 150, height: 150)
    let trimBox = CGRect(x: 10, y: 10, width: 130, height: 130)
    let draws: [(CGContext) -> Void] = (1...3).map { i in
      { ctx in
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(mediaBox)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: Double(i * 10), y: 60, width: 20, height: 20))
      }
    }
    Self.makeMultiPageFixture(
      mediaBox: mediaBox, trimBoxes: [trimBox, trimBox, trimBox], draws: draws, to: source)

    let output = try await runTrim(input: source, dir: dir)
    XCTAssertEqual(CGPDFDocument(output as CFURL)?.numberOfPages, 3)
  }

  // MARK: - 3. Sayfadan sayfaya farklı TrimBox

  func testDifferentTrimBoxPerPage() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("varying.pdf")
    let mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
    let trimA = CGRect(x: 10, y: 10, width: 100, height: 150)
    let trimB = CGRect(x: 5, y: 5, width: 190, height: 60)
    let whiteFill: (CGContext) -> Void = { ctx in
      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      ctx.fill(mediaBox)
    }
    Self.makeMultiPageFixture(
      mediaBox: mediaBox, trimBoxes: [trimA, trimB], draws: [whiteFill, whiteFill], to: source)

    let output = try await runTrim(input: source, dir: dir)
    guard let doc = CGPDFDocument(output as CFURL) else { return XCTFail("çıktı açılamadı") }
    XCTAssertEqual(doc.numberOfPages, 2)
    guard let page1 = doc.page(at: 1), let page2 = doc.page(at: 2) else {
      return XCTFail("sayfalar açılamadı")
    }
    let box1 = page1.getBoxRect(.mediaBox)
    let box2 = page2.getBoxRect(.mediaBox)
    XCTAssertEqual(box1.width, trimA.width, accuracy: 0.5)
    XCTAssertEqual(box1.height, trimA.height, accuracy: 0.5)
    XCTAssertEqual(box2.width, trimB.width, accuracy: 0.5)
    XCTAssertEqual(box2.height, trimB.height, accuracy: 0.5)
  }

  // MARK: - 4. TrimBox yoksa sayfa bozulmuyor

  func testNoTrimBoxPassesPageUnchanged() async throws {
    let dir = try makeTempDirectory()
    let source = dir.appendingPathComponent("notrim.pdf")
    let mediaBox = CGRect(x: 0, y: 0, width: 180, height: 120)
    Self.makeFixture(mediaBox: mediaBox, trimBox: nil, to: source) { ctx in
      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      ctx.fill(mediaBox)
      // Kenara YAPIŞIK bir işaret — kırpma OLSAYDI (yanlışlıkla) bu kaybolurdu.
      ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    }

    let output = try await runTrim(input: source, dir: dir)
    guard let doc = CGPDFDocument(output as CFURL), let page = doc.page(at: 1) else {
      return XCTFail("çıktı açılamadı")
    }
    let outputBox = page.getBoxRect(.mediaBox)
    XCTAssertEqual(outputBox.width, mediaBox.width, accuracy: 0.5)
    XCTAssertEqual(outputBox.height, mediaBox.height, accuracy: 0.5)

    guard let color = Self.averageColor(of: output, region: CGRect(x: 1, y: 1, width: 8, height: 8))
    else { return XCTFail("örnekleme başarısız") }
    XCTAssertGreaterThan(color.r, 0.7, "kırmızı işaret kayıp — TrimBox yokken sayfa kırpılmış")
    XCTAssertLessThan(color.g, 0.3)
    XCTAssertLessThan(color.b, 0.3)
  }

  // MARK: - 5. Döndürme: kutu takası + içerik doğru yönde

  func testRotatedPagePreservesOrientationAndSwapsBox() async throws {
    let dir = try makeTempDirectory()
    let plain = dir.appendingPathComponent("plain.pdf")
    let mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
    // Yatay (landscape) TrimBox — 90°'de dikey (160×260) olması BEKLENİR.
    let trimBox = CGRect(x: 20, y: 20, width: 260, height: 160)
    // Marker: TrimBox'ın SOL-ÜST köşesi (kaynak/rotasyonsuz uzayda düşük x, yüksek y).
    let markerRegion = CGRect(x: trimBox.minX, y: trimBox.maxY - 30, width: 30, height: 30)
    Self.makeFixture(mediaBox: mediaBox, trimBox: trimBox, to: plain) { ctx in
      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      ctx.fill(mediaBox)
      ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      ctx.fill(markerRegion)
    }

    // qpdf `--rotate` yalnız `/Rotate`'i yazar; TrimBox/marker koordinatları AYNI kalır (bkz. dosya
    // üstü notu) — bu yüzden `rotated`'ın kendi TrimBox'ı hâlâ `trimBox`, marker'ı hâlâ `markerRegion`.
    let rotated = try await rotateFirstPage(of: plain, degrees: 90, dir: dir)
    guard let rotatedPage = CGPDFDocument(rotated as CFURL)?.page(at: 1) else {
      return XCTFail("döndürülmüş fixture açılamadı")
    }
    XCTAssertEqual(rotatedPage.rotationAngle, 90, "fixture'ın kendisi 90° döndürülmüş olmalı")

    let output = try await runTrim(input: rotated, dir: dir)
    guard let outDoc = CGPDFDocument(output as CFURL), let outPage = outDoc.page(at: 1) else {
      return XCTFail("kesim çıktısı açılamadı")
    }
    XCTAssertEqual(outDoc.numberOfPages, 1)

    // Kutu EN/BOY TAKASI: kaynakta 260×160 (yatay) olan TrimBox, 90°'de GÖRSEL olarak 160×260
    // (dikey) olmalı — bu görev şartının kalbi.
    let outputBox = outPage.getBoxRect(.mediaBox)
    XCTAssertEqual(outputBox.width, trimBox.height, accuracy: 0.5, "çıktı genişliği takas edilmemiş")
    XCTAssertEqual(outputBox.height, trimBox.width, accuracy: 0.5, "çıktı yüksekliği takas edilmemiş")

    // NOT (dürüstçe): çıktının KENDİ `/Rotate`'i burada 0'dır — `CGPDFContext`'in sayfa sözlüğü
    // `/Rotate` YAZDIRMIYOR (bkz. CoreGraphicsTrimEngine.swift dosya üstü notu, CGPDFContext.h'de
    // doğrulandı), bu yüzden rotasyon METADATA olarak DEĞİL, İÇERİĞE PİŞİRİLEREK korunuyor — aşağıki
    // köşe kontrolleri bunun GÖRSEL olarak doğru sonuç verdiğini kanıtlıyor.
    XCTAssertEqual(outPage.rotationAngle, 0, "rotasyon içeriğe pişirildiği için çıktı /Rotate 0 olmalı")

    // İÇERİK YÖNÜ: PDF /Rotate saat yönünde döndürür (ISO 32000) — kaynağın SOL-ÜST köşesi 90°'de
    // SAĞ-ÜST köşeye gelir (TL→TR). DOĞRULANDI (scratchpad probe4, 2026-09-09): aynı sayfa/aynı
    // `getDrawingTransform` çağrısı BAĞIMSIZ bir betikte elle uygulanıp `markerRegion`'ın dört köşesi
    // izlendi — tam olarak çıktı-uzayı x:[130,160] y:[230,260]'a düşüyor (kutunun sağ-üst köşesi).
    // Örnekleme penceresi bilerek bunun birkaç punto İÇİNE çekildi (antialiasing/kenar payı).
    guard
      let topRight = Self.averageColor(
        of: output, region: CGRect(x: 138, y: 238, width: 14, height: 14))
    else { return XCTFail("sağ-üst örnekleme başarısız") }
    XCTAssertGreaterThan(topRight.r, 0.9, "marker sağ-üstte değil — döndürme yanlış yönde/eksik")
    XCTAssertLessThan(topRight.g, 0.2)
    XCTAssertLessThan(topRight.b, 0.2)

    // Kontrol: çapraz köşe (sol-alt) TEMİZ olmalı — marker "eski" (rotasyonsuz) konumunda KALMIŞ
    // olsaydı (bilinen kusurun ta kendisi) burada değil, çıktının SOL-ALT köşesine yakın bir yerde
    // görünürdü; o köşenin beyaz kalması rotasyonun gerçekten uygulandığının bağımsız kanıtı.
    guard
      let bottomLeft = Self.averageColor(
        of: output, region: CGRect(x: 5, y: 5, width: 30, height: 30))
    else { return XCTFail("sol-alt örnekleme başarısız") }
    XCTAssertGreaterThan(bottomLeft.r, 0.9, "sol-alt köşe kırmızı — marker hâlâ eski konumda")
    XCTAssertGreaterThan(bottomLeft.g, 0.9)
    XCTAssertGreaterThan(bottomLeft.b, 0.9)
  }
}
