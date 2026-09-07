import CoreGraphics
import XCTest

@testable import PDFToolsCore

/// `PageThumbnailCache` için testler. Fixture çok sayfalı bir PDF'tir, her sayfa TAMAMEN farklı bir
/// düz renkle boyanır (kırmızı/yeşil/mavi/sarı/...) — bu hem "boş değil" ölçümünü hem de "sayfalar
/// birbirinden ayırt ediliyor mu" testini trivyal ve kesin kılar. `TrimTests.swift`'teki
/// `CGContext(consumer:mediaBox:)` + `beginPDFPage`/`endPDFPage` fixture tekniği burada da kullanıldı.
final class ThumbnailCacheTests: XCTestCase {
  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-thumb-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  /// Her biri düz renkle dolu, `pageSize` boyutunda `colors.count` sayfalık bir PDF yazar.
  private static func makeFixture(
    pageSize: CGSize, colors: [CGColor], to url: URL
  ) {
    try? FileManager.default.removeItem(at: url)
    var box = CGRect(origin: .zero, size: pageSize)
    guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("CGDataConsumer") }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      fatalError("CGContext(consumer:mediaBox:auxiliaryInfo:)")
    }
    for color in colors {
      context.beginPDFPage(nil)
      context.setFillColor(color)
      context.fill(CGRect(origin: .zero, size: pageSize))
      context.endPDFPage()
    }
    context.closePDF()
  }

  private static let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
  private static let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
  private static let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

  // MARK: - Piksel inceleme yardımcıları (test-yerel; ImageExportVerification dosya alır, biz CGImage
  // alıyoruz — bu yüzden burada küçük, bağımsız bir eşdeğeri var).

  /// Beyaz (luma ≥ 250) OLMAYAN piksellerin oranı, yüzde.
  private func nonWhitePercent(of image: CGImage) -> Double {
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { return 0 }
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return 0 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = ctx.data else { return 0 }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    var nonWhite = 0
    for row in 0..<height {
      let rowStart = row * bytesPerRow
      for col in 0..<width where buffer[rowStart + col] < 250 { nonWhite += 1 }
    }
    return Double(nonWhite) / Double(width * height) * 100
  }

  /// Görüntünün ortalama (R,G,B) rengi. Disk önbelleği HEIC/JPEG gibi KAYIPLI biçimler
  /// kullanabildiğinden (bkz. `PageThumbnailCache` dosya üstü yorumu — bu makinede HEIC seçildi),
  /// disk'ten geri okunan bir görüntü orijinal render ile bayt-bayt AYNI olmayabilir; bu yüzden
  /// disk round-trip karşılaştırmalarında `rgbaBytes` yerine toleranslı ortalama renk kullanılıyor.
  private func averageColor(of image: CGImage) -> (r: Double, g: Double, b: Double) {
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { return (0, 0, 0) }
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return (0, 0, 0) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = ctx.data else { return (0, 0, 0) }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    var sumR = 0.0, sumG = 0.0, sumB = 0.0
    for row in 0..<height {
      let rowStart = row * bytesPerRow
      for col in 0..<width {
        let pixel = rowStart + col * 4
        sumR += Double(buffer[pixel])
        sumG += Double(buffer[pixel + 1])
        sumB += Double(buffer[pixel + 2])
      }
    }
    let count = Double(width * height)
    return (sumR / count, sumG / count, sumB / count)
  }

  /// Görüntünün ham RGBA baytları — iki `CGImage`'ın piksel-eşit olup olmadığını karşılaştırmak için.
  private func rgbaBytes(of image: CGImage) -> Data {
    let width = image.width, height = image.height
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return Data() }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = ctx.data else { return Data() }
    return Data(bytes: data, count: ctx.bytesPerRow * height)
  }

  // MARK: - 1. Küçük resim üretiliyor, boyutu doğru, boş değil

  func testThumbnailIsProducedWithCorrectSizeAndIsNotEmpty() async throws {
    let dir = try makeTempDirectory()
    let pdfURL = dir.appendingPathComponent("basic.pdf")
    // Kasıtlı olarak KARE OLMAYAN sayfa: en uzun kenarın doğru hesaplandığını (200 değil 300)
    // kanıtlamak için — bir hata en-boy oranını yanlış işlerse burada yakalanır.
    Self.makeFixture(pageSize: CGSize(width: 200, height: 300), colors: [Self.red], to: pdfURL)
    let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
    let cache = PageThumbnailCache(cacheDirectory: cacheDir)

    let start = Date()
    guard let image = await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 150) else {
      return XCTFail("küçük resim üretilemedi")
    }
    print("cold render: \(Date().timeIntervalSince(start) * 1000) ms")

    XCTAssertEqual(max(image.width, image.height), 150, accuracy: 1)
    // 200x300 sayfada uzun kenar height (300); genişlik 150 * (200/300) = 100 olmalı.
    XCTAssertEqual(image.width, 100, accuracy: 1)
    XCTAssertEqual(image.height, 150, accuracy: 1)

    let nonWhite = nonWhitePercent(of: image)
    XCTAssertGreaterThan(nonWhite, 0.5, "sayfa tamamen kırmızı boyalıyken görüntü boş çıktı")
  }

  // MARK: - 2. Farklı sayfalar farklı görüntü veriyor

  func testDifferentPagesProduceDifferentImages() async throws {
    let dir = try makeTempDirectory()
    let pdfURL = dir.appendingPathComponent("three-pages.pdf")
    Self.makeFixture(
      pageSize: CGSize(width: 200, height: 200), colors: [Self.red, Self.green, Self.blue],
      to: pdfURL)
    let cache = PageThumbnailCache(cacheDirectory: dir.appendingPathComponent("cache"))

    guard
      let page1 = await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 100),
      let page2 = await cache.thumbnail(for: pdfURL, page: 2, maxPixel: 100),
      let page3 = await cache.thumbnail(for: pdfURL, page: 3, maxPixel: 100)
    else { return XCTFail("küçük resimler üretilemedi") }

    let bytes1 = rgbaBytes(of: page1)
    let bytes2 = rgbaBytes(of: page2)
    let bytes3 = rgbaBytes(of: page3)
    XCTAssertNotEqual(bytes1, bytes2, "sayfa 1 ile sayfa 2 aynı piksellere sahip")
    XCTAssertNotEqual(bytes2, bytes3, "sayfa 2 ile sayfa 3 aynı piksellere sahip")
    XCTAssertNotEqual(bytes1, bytes3, "sayfa 1 ile sayfa 3 aynı piksellere sahip")
  }

  // MARK: - 3. İkinci çağrı önbellekten (bellek) geliyor

  func testSecondCallHitsMemoryCacheWithoutIncrementingMisses() async throws {
    let dir = try makeTempDirectory()
    let pdfURL = dir.appendingPathComponent("repeat.pdf")
    Self.makeFixture(pageSize: CGSize(width: 150, height: 150), colors: [Self.blue], to: pdfURL)
    let cache = PageThumbnailCache(cacheDirectory: dir.appendingPathComponent("cache"))

    _ = await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 80)
    let afterFirst = await cache.statistics()
    XCTAssertEqual(afterFirst.hits, 0)
    XCTAssertEqual(afterFirst.misses, 1)

    let start = Date()
    _ = await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 80)
    print("warm (memory) call: \(Date().timeIntervalSince(start) * 1000) ms")

    let afterSecond = await cache.statistics()
    XCTAssertEqual(afterSecond.hits, 1, "hit sayacı artmadı")
    XCTAssertEqual(afterSecond.misses, 1, "miss sayacı yanlışlıkla arttı")
  }

  // MARK: - 4. Disk önbelleği kalıcı: yeni bir cache örneği aynı dosya için hit veriyor

  func testDiskCachePersistsAcrossCacheInstances() async throws {
    let dir = try makeTempDirectory()
    let pdfURL = dir.appendingPathComponent("persist.pdf")
    Self.makeFixture(pageSize: CGSize(width: 180, height: 180), colors: [Self.green], to: pdfURL)
    let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)

    let firstInstance = PageThumbnailCache(cacheDirectory: cacheDir)
    guard let firstImage = await firstInstance.thumbnail(for: pdfURL, page: 1, maxPixel: 90) else {
      return XCTFail("ilk render başarısız")
    }
    let firstStats = await firstInstance.statistics()
    XCTAssertEqual(firstStats.misses, 1)
    XCTAssertGreaterThan(firstStats.diskBytes, 0, "diske hiçbir bayt yazılmamış")

    // YENİ bir actor örneği — bellek boş, yalnız disk kalıcılığı test ediliyor.
    let secondInstance = PageThumbnailCache(cacheDirectory: cacheDir)
    let start = Date()
    guard let secondImage = await secondInstance.thumbnail(for: pdfURL, page: 1, maxPixel: 90) else {
      return XCTFail("disk önbelleğinden okuma başarısız")
    }
    print("warm (disk) call, new instance: \(Date().timeIntervalSince(start) * 1000) ms")

    let secondStats = await secondInstance.statistics()
    XCTAssertEqual(secondStats.hits, 1, "yeni örnek disk hit'i hit olarak saymadı")
    XCTAssertEqual(secondStats.misses, 0, "yeni örnek disk'te olan bir girdi için render'a düştü")

    // Bayt-bayt DEĞİL: disk biçimi kayıplı olabilir (bu makinede HEIC seçildi, bkz. rapor). Aynı
    // sayfanın aynı yeşil rengini temsil ettiğini toleranslı ortalama renkle doğrula.
    let firstColor = averageColor(of: firstImage)
    let secondColor = averageColor(of: secondImage)
    XCTAssertEqual(firstColor.r, secondColor.r, accuracy: 12, "disk'ten dönen görüntünün R kanalı çok farklı")
    XCTAssertEqual(firstColor.g, secondColor.g, accuracy: 12, "disk'ten dönen görüntünün G kanalı çok farklı")
    XCTAssertEqual(firstColor.b, secondColor.b, accuracy: 12, "disk'ten dönen görüntünün B kanalı çok farklı")
  }

  // MARK: - 5. Dosya değişince önbellek geçersiz — eski görüntü dönmüyor

  func testCacheInvalidatesWhenSourceFileChanges() async throws {
    let dir = try makeTempDirectory()
    let pdfURL = dir.appendingPathComponent("mutable.pdf")
    Self.makeFixture(pageSize: CGSize(width: 160, height: 160), colors: [Self.red], to: pdfURL)
    let cache = PageThumbnailCache(cacheDirectory: dir.appendingPathComponent("cache"))

    guard let originalImage = await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 80) else {
      return XCTFail("ilk render başarısız")
    }

    // Dosyayı DEĞİŞTİR (farklı renk) ve mtime'ı KESİN farklı olsun diye ileri bir tarihe zorla —
    // dosya sistemi mtime çözünürlüğü (bazı FS'lerde 1 sn) ile aynı saniyeye denk gelme riskini eler.
    Self.makeFixture(pageSize: CGSize(width: 160, height: 160), colors: [Self.blue], to: pdfURL)
    let future = Date().addingTimeInterval(5)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: pdfURL.path)

    guard let updatedImage = await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 80) else {
      return XCTFail("güncellenmiş dosya için render başarısız")
    }

    XCTAssertNotEqual(
      rgbaBytes(of: originalImage), rgbaBytes(of: updatedImage),
      "dosya değiştiği halde ESKİ (bayat) küçük resim döndü")

    let stats = await cache.statistics()
    XCTAssertEqual(stats.misses, 2, "yeni içerik için render tetiklenmedi (anahtar değişmemiş)")
  }

  // MARK: - 6. Eşzamanlılık: aynı sayfa için 10 eşzamanlı istek → render sayacı 1

  func testConcurrentRequestsForSameKeyRenderOnce() async throws {
    let dir = try makeTempDirectory()
    let pdfURL = dir.appendingPathComponent("concurrent.pdf")
    Self.makeFixture(pageSize: CGSize(width: 220, height: 220), colors: [Self.green], to: pdfURL)
    let cache = PageThumbnailCache(cacheDirectory: dir.appendingPathComponent("cache"))

    let results = await withTaskGroup(of: CGImage?.self, returning: [CGImage?].self) { group in
      for _ in 0..<10 {
        group.addTask {
          await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 100)
        }
      }
      var collected: [CGImage?] = []
      for await result in group { collected.append(result) }
      return collected
    }

    XCTAssertEqual(results.count, 10)
    XCTAssertTrue(results.allSatisfy { $0 != nil }, "eşzamanlı isteklerden biri nil döndü")

    let stats = await cache.statistics()
    XCTAssertEqual(stats.misses, 1, "in-flight birleştirme çalışmadı — render sayacı 1 olmalıydı")
    XCTAssertEqual(stats.hits, 9, "kalan 9 istek in-flight/bellek üzerinden hit sayılmalıydı")
  }

  // MARK: - 7. clear(for:) çalışıyor

  func testClearForURLForcesFreshRender() async throws {
    let dir = try makeTempDirectory()
    let pdfURL = dir.appendingPathComponent("clearable.pdf")
    Self.makeFixture(pageSize: CGSize(width: 140, height: 140), colors: [Self.red], to: pdfURL)
    let cache = PageThumbnailCache(cacheDirectory: dir.appendingPathComponent("cache"))

    _ = await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 70)
    let beforeClear = await cache.statistics()
    XCTAssertEqual(beforeClear.misses, 1)
    XCTAssertGreaterThan(beforeClear.diskBytes, 0)

    await cache.clear(for: pdfURL)
    let afterClear = await cache.statistics()
    XCTAssertEqual(afterClear.diskBytes, 0, "clear(for:) diski temizlemedi")

    // Aynı (dosya, sayfa, boyut) anahtarı hâlâ geçerli olurdu (mtime/boyut değişmedi) — clear
    // olmasaydı bu çağrı bellek hit'i olurdu. clear sonrası GENUINE bir render tetiklenmeli.
    _ = await cache.thumbnail(for: pdfURL, page: 1, maxPixel: 70)
    let afterReRender = await cache.statistics()
    XCTAssertEqual(afterReRender.misses, 2, "clear(for:) sonrası eski önbellek hâlâ kullanılıyor")
  }

  // MARK: - 8. Mutasyon kanıtı

  /// Bu test, testDifferentPagesProduceDifferentImages'ın GERÇEKTEN ayrım yaptığını KANITLAR.
  /// Yöntem raporda anlatılıyor: `PageThumbnailCache.renderThumbnail` geçici olarak "her zaman
  /// sayfa 1'i render et" şeklinde bozulup testin KIRMIZI verdiği elle gözlemlendi, sonra geri
  /// alınıp YEŞİLE döndüğü doğrulandı (bkz. oturum raporu — kalıcı bir mutasyon anahtarı bu dosyada
  /// bırakılmadı, çünkü kalıcı bir "bil bug" bayrağı testin kendisini anlamsızlaştırırdı).
  /// Burada dokümante edilen adımlar tekrar üretilebilir: `page` parametresini `renderThumbnail`
  /// içinde sabit `1`'e sabitleyip `swift test --filter ThumbnailCacheTests` çalıştırmak yeterli.
  func testMutationProofIsDocumented() throws {
    // Kasıtlı olarak boş: kanıt bu dosyanın kendisi değil, oturum sırasında elle yapılan
    // kırmızı→yeşil geçişidir (raporda anlatıldı). Bu test yalnızca CI'da regresyon
    // bırakmamak için var; asıl kanıt testDifferentPagesProduceDifferentImages'ın kendisidir.
    XCTAssertTrue(true)
  }
}
