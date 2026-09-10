import CoreGraphics
import Foundation

/// "Kesim Payını At" çıktısının kesim payını GERÇEKTEN atıp atmadığını ölçer. Kutu üstverisine
/// (MediaBox/CropBox) güvenmez — motorlar (özellikle gs, bkz. GhostscriptEngine.swift) kutuyu
/// küçültüp içeriği kırpmadan bırakabilir. Yöntem: çıktı sayfasının KENDİ bildirdiği kutusunu her
/// yönde `marginPoints` genişletip render et; eski sınırın DIŞINDA kalan banttaki beyaz olmayan
/// piksel oranına bak. Bu yöntem `.claude/docs/yol-haritasi-2026-09.md`'de gerçek bir matbaa
/// dosyasıyla (300 dpi / 30pt bant) doğrulandı; burada operasyonel maliyeti düşük tutmak için
/// 150 dpi / 8,5pt (≈ 3 mm — ölçülen gerçek kesim payı) kullanılır.
public enum TrimVerification {
  public enum Verdict: Sendable, Equatable {
    /// Bant tamamen (< %2) temiz — kesim payı gerçekten silinmiş.
    case clean
    /// Bantta iz var (%2–%10) ama küçük — çıktı korunur, kullanıcıya oran gösterilir.
    case partial
    /// Bant büyük ölçüde dolu (> %10) — kesim payı fiilen silinmemiş, çıktı reddedilir.
    case failed
  }

  public struct Result: Sendable, Equatable {
    public let residuePercent: Double
    public let verdict: Verdict
  }

  /// İnceleme bandı genişliği (punto). Gerçek matbaa dosyasında ölçülen kesim payıyla eşleşir.
  public static let marginPoints: CGFloat = 8.5
  public static let renderDPI: CGFloat = 150
  /// Bu luma değerinin (0–255, gri tonlama) altı "mürekkep var" sayılır; 255 saf beyaz.
  private static let inkLumaThreshold: UInt8 = 245
  private static let cleanThreshold: Double = 2.0
  private static let failedThreshold: Double = 10.0

  /// `url`'deki PDF'in ilk sayfasını inceler. Sayfa açılamıyorsa ya da kutusu dejenereyse
  /// güvenli tarafta kalıp `.failed` döner (kanıtsız "temiz" raporlamamak için).
  public static func verify(_ url: URL) -> Result {
    guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    let originalBox = page.getBoxRect(.mediaBox)
    guard originalBox.width > 0, originalBox.height > 0 else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    let expanded = originalBox.insetBy(dx: -marginPoints, dy: -marginPoints)
    let scale = renderDPI / 72.0
    let pxWidth = max(1, Int((expanded.width * scale).rounded(.up)))
    let pxHeight = max(1, Int((expanded.height * scale).rounded(.up)))

    guard
      let ctx = CGContext(
        data: nil, width: pxWidth, height: pxHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    // Beyaz zemin: sayfa dışına taşan hiçbir şey yoksa bant tamamen beyaz kalır.
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -expanded.origin.x, y: -expanded.origin.y)
    // Not: CGContext.drawPDFPage kutuya göre KIRPMAZ (Apple dokümantasyonu) — tam da bunu
    // istiyoruz: sayfanın bildirdiği kutunun dışında kalan gerçek içeriği görünür kılmak.
    ctx.drawPDFPage(page)

    guard let data = ctx.data else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * pxHeight)

    var bandPixels = 0
    var inkPixels = 0
    for row in 0..<pxHeight {
      // CGContext(data: nil, ...) ile oluşturulan gri tonlamalı bitmap'in ham arabelleği satır 0
      // = görüntünün ÜSTÜ (en yüksek kullanıcı-uzayı y'si) ile başlıyor — ekstra flip UYGULANMADI,
      // bu proje içinde ölçülüp doğrulandı (bkz. oturum notları / scratchpad ölçümü, 2026-09-07).
      let userY = expanded.maxY - (Double(row) + 0.5) / Double(scale)
      let rowStart = row * bytesPerRow
      for col in 0..<pxWidth {
        let userX = expanded.origin.x + (Double(col) + 0.5) / Double(scale)
        guard !originalBox.contains(CGPoint(x: userX, y: userY)) else { continue }
        bandPixels += 1
        if buffer[rowStart + col] < inkLumaThreshold {
          inkPixels += 1
        }
      }
    }

    let percent = bandPixels == 0 ? 0 : Double(inkPixels) / Double(bandPixels) * 100
    let verdict: Verdict
    if percent < cleanThreshold {
      verdict = .clean
    } else if percent <= failedThreshold {
      verdict = .partial
    } else {
      verdict = .failed
    }
    return Result(residuePercent: percent, verdict: verdict)
  }
}

// MARK: - Kutu geometrisi ve içerik sadakati kapıları
//
// Bu iki kapı 2026-09-10'daki saha arızasından SONRA eklendi. O gün öğrenilen şey: yukarıdaki
// bant ölçümü (kesim payı gerçekten gitti mi?) TEK BAŞINA yetmiyor — çıktı kesim payını atmış
// olabilir ve yine de (a) yanlış sayfa boyutuna, (b) kaynaktan farklı görünen içeriğe sahip
// olabilir. İkisi de kullanıcının fark etmesi zor, geri dönüşü olan hasar türleri.
extension TrimVerification {
  /// Çıktının SAYFA GEOMETRİSİ doğru mu: her sayfanın boyutu kaynağın o sayfadaki TrimBox'ı
  /// kadar mı ve çıktıda hâlâ kesim payı bildiren sayfa kaldı mı.
  public struct Geometry: Sendable, Equatable {
    public let checkedPages: Int
    public let pageCountMatches: Bool
    /// Boyutu beklenenden farklı çıkan İLK sayfanın 1-tabanlı numarası.
    public let firstMismatch: Int?
    /// Çıktıda TrimBox'ı hâlâ MediaBox'tan farklı olan sayfa sayısı (0 olmalı — yoksa kullanıcı
    /// aynı dosyada işlemi ikinci kez uygulanabilir görür).
    public let pagesStillDeclaringBleed: Int

    public var isCorrect: Bool {
      pageCountMatches && firstMismatch == nil && pagesStillDeclaringBleed == 0
    }
  }

  /// TÜM sayfalar kontrol edilir (örnekleme YOK): kutu okuma yalnızca üstveri, 130 sayfalık gerçek
  /// bir dosyada ölçülen maliyet milisaniyeler. Kesim payı bazı dosyalarda sayfadan sayfaya
  /// değişiyor; örneklemek tam da o dosyalarda hatayı kaçırırdı.
  public static func geometry(source: URL, output: URL) -> Geometry {
    guard let sourceDocument = CGPDFDocument(source as CFURL),
      let outputDocument = CGPDFDocument(output as CFURL)
    else {
      return Geometry(
        checkedPages: 0, pageCountMatches: false, firstMismatch: 1, pagesStillDeclaringBleed: 0)
    }
    let sourceCount = sourceDocument.numberOfPages
    let outputCount = outputDocument.numberOfPages
    guard sourceCount > 0, sourceCount == outputCount else {
      return Geometry(
        checkedPages: 0, pageCountMatches: sourceCount == outputCount, firstMismatch: nil,
        pagesStillDeclaringBleed: 0)
    }

    var firstMismatch: Int?
    var stillBleeding = 0
    for index in 1...sourceCount {
      guard let sourcePage = sourceDocument.page(at: index),
        let outputPage = outputDocument.page(at: index)
      else { continue }
      let expected = sourcePage.getBoxRect(.trimBox).size
      let actualBox = outputPage.getBoxRect(.mediaBox)
      // Boyutlar SIRASIZ karşılaştırılır (küçük/büyük olarak): sayfayı yeniden yazan kip döndürmeyi
      // içeriğe pişirip 90°/270° sayfalarda en/boyu takas ediyor (bkz. CoreGraphicsTrimEngine),
      // kayıpsız kip ise `/Rotate`i olduğu gibi bırakıyor. İkisi de DOĞRU; bu kapının işi
      // döndürmeyi denetlemek değil, YANLIŞ ÖLÇÜ yakalamak.
      if !sizesMatch(expected, actualBox.size), firstMismatch == nil {
        firstMismatch = index
      }
      if boxesDiffer(outputPage.getBoxRect(.trimBox), actualBox) {
        stillBleeding += 1
      }
    }
    return Geometry(
      checkedPages: sourceCount, pageCountMatches: true, firstMismatch: firstMismatch,
      pagesStillDeclaringBleed: stillBleeding)
  }

  /// Çıktının İÇERİĞİ kaynakla aynı mı görünüyor. Kesim payını atmak sayfayı KÜÇÜLTÜR, içeriği
  /// DEĞİŞTİRMEZ — bu kapı tam bunu ölçüyor ve 2026-09-10'da gözden kaçan hasar sınıfını
  /// (renk uzayı dönüşümü, saydamlık düzleştirme, boş sayfa) yakalıyor.
  public struct Fidelity: Sendable, Equatable {
    public let comparedPages: Int
    /// Kaynakla çıktı arasında farklı olan piksel oranı (%).
    public let differingPixelPercent: Double
    /// En büyük tek kanal farkı (0–255). Ortalama fark YETERSİZ bir ölçüt: ölçülen bir vakada
    /// ortalama 0,02/255 iken en büyük fark 250/255'ti — yani "neredeyse aynı" görünen ortalama,
    /// gözle görülen çizgi/ton kaymalarını gizliyordu.
    public let maxChannelDelta: Int

    public var isFaithful: Bool { comparedPages > 0 && differingPixelPercent <= faithfulPercent }
  }

  /// Kayıpsız kipte beklenen değer 0,00 (ölçüldü: üç gerçek dosyada piksel birebir aynı).
  /// Eşik yine de sıfır DEĞİL: render dönüşümündeki kayan nokta yuvarlaması kenar piksellerinde
  /// bir tık oynayabilir. %0,5 hâlâ boş sayfayı, renk kaymasını ve kırpma hatasını yakalar.
  public static let faithfulPercent: Double = 0.5
  /// Bu eşiğin altındaki kanal farkı "aynı piksel" sayılır (kenar yumuşatma gürültüsü).
  private static let sameChannelTolerance: UInt8 = 2

  public static func fidelity(source: URL, output: URL, sampleLimit: Int = 3, dpi: CGFloat = 100)
    -> Fidelity
  {
    guard let sourceDocument = CGPDFDocument(source as CFURL),
      let outputDocument = CGPDFDocument(output as CFURL)
    else {
      return Fidelity(comparedPages: 0, differingPixelPercent: 100, maxChannelDelta: 255)
    }
    let count = min(sourceDocument.numberOfPages, outputDocument.numberOfPages)
    guard count > 0 else {
      return Fidelity(comparedPages: 0, differingPixelPercent: 100, maxChannelDelta: 255)
    }

    var comparedPages = 0
    var differing = 0
    var total = 0
    var maxDelta = 0
    for index in sampleIndices(count: count, limit: sampleLimit) {
      guard let sourcePage = sourceDocument.page(at: index),
        let outputPage = outputDocument.page(at: index)
      else { continue }
      let box = sourcePage.getBoxRect(.trimBox)
      let rotated = CoreGraphicsTrimEngine.normalizedRotation(sourcePage.rotationAngle)
      let visual =
        (rotated == 90 || rotated == 270)
        ? CGSize(width: box.height, height: box.width) : box.size
      let scale = dpi / 72.0
      let width = max(1, Int((visual.width * scale).rounded()))
      let height = max(1, Int((visual.height * scale).rounded()))
      guard let expected = render(sourcePage, width: width, height: height),
        let actual = render(outputPage, width: width, height: height),
        let expectedData = expected.data, let actualData = actual.data
      else { continue }
      comparedPages += 1
      let expectedBuffer = expectedData.bindMemory(
        to: UInt8.self, capacity: expected.bytesPerRow * height)
      let actualBuffer = actualData.bindMemory(to: UInt8.self, capacity: actual.bytesPerRow * height)
      for row in 0..<height {
        let expectedRow = row * expected.bytesPerRow
        let actualRow = row * actual.bytesPerRow
        for column in 0..<width {
          total += 1
          let delta = Int(expectedBuffer[expectedRow + column]) - Int(actualBuffer[actualRow + column])
          let magnitude = abs(delta)
          if magnitude > Int(sameChannelTolerance) { differing += 1 }
          if magnitude > maxDelta { maxDelta = magnitude }
        }
      }
    }
    guard comparedPages > 0, total > 0 else {
      return Fidelity(comparedPages: 0, differingPixelPercent: 100, maxChannelDelta: 255)
    }
    return Fidelity(
      comparedPages: comparedPages,
      differingPixelPercent: Double(differing) / Double(total) * 100, maxChannelDelta: maxDelta)
  }

  /// İlk, orta ve son sayfa. Kesim hatası tipik olarak ya her sayfada olur ya da belgenin bir
  /// ucundadır (ilk/son sayfa farklı şablondan gelir) — üç nokta bu iki durumu da görüyor.
  static func sampleIndices(count: Int, limit: Int) -> [Int] {
    guard limit > 0 else { return [] }
    var indices = [1]
    if count > 2 { indices.append((count + 1) / 2) }
    if count > 1 { indices.append(count) }
    var seen = Set<Int>()
    return indices.filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
  }

  /// Sayfanın KESİM ALANINI görsel yönde (kendi `/Rotate` açısı uygulanmış) gri tonlamalı bitmap'e
  /// çizer. `getDrawingTransform` kutuyu hedef dikdörtgene ortalayıp ölçeklediği için kaynak ile
  /// çıktının kutu köşeleri farklı olsa bile (kayıpsız kip kutuyu yerinde bırakır, yeniden yazan
  /// kip 0,0'a taşır) iki render AYNI çerçeveye oturuyor — kapı iki kipte de anlamlı.
  static func render(_ page: CGPDFPage, width: Int, height: Int) -> CGContext? {
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let target = CGRect(x: 0, y: 0, width: width, height: height)
    ctx.concatenate(
      page.getDrawingTransform(.trimBox, rect: target, rotate: 0, preserveAspectRatio: true))
    ctx.clip(to: page.getBoxRect(.trimBox))
    ctx.drawPDFPage(page)
    return ctx
  }

  static func sizesMatch(_ a: CGSize, _ b: CGSize) -> Bool {
    let first = [a.width, a.height].sorted()
    let second = [b.width, b.height].sorted()
    return abs(first[0] - second[0]) < 1 && abs(first[1] - second[1]) < 1
  }

  static func boxesDiffer(_ a: CGRect, _ b: CGRect) -> Bool {
    QPDFTrimEngine.boxesDiffer(a, b)
  }
}
