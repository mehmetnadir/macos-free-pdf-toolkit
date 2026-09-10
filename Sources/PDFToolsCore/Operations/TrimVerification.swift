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

  public static let renderDPI: CGFloat = 150
  /// KENAR YUMUŞATMA PAYI (punto). Kırpma yolu tam kutu sınırına oturduğunda render, sınıra
  /// değen piksel satırını yarı tonla boyuyor — bu MÜREKKEP DEĞİL, kenar yumuşatmadır.
  /// Ölçüldü (2026-09-11, bağımsız yol: kutuyu qpdf ile geri büyüt + gs ile 300 dpi render):
  /// kırpılmış çıktıda kutu dışındaki mürekkebin %100'ü sınırdan 1 pikselin içinde, en uzak
  /// mürekkep 0,01 pt. Pay olmadan kapı "silik iz var" diye YANLIŞ ALARM veriyordu.
  /// 0,5 pt ≈ 150 dpi'da 1 piksel; gerçek kesim payı (3 mm = 8,5 pt) buna göre 17 kat büyük,
  /// yani kapı hâlâ gerçek kalıntıyı görüyor (`TrimTests` ve mutasyonla kanıtlı).
  public static let antialiasGuardPoints: CGFloat = 0.5
  /// Bu luma değerinin (0–255, gri tonlama) altı "mürekkep var" sayılır; 255 saf beyaz.
  static let inkLumaThreshold: UInt8 = 245
  private static let cleanThreshold: Double = 2.0
  private static let failedThreshold: Double = 10.0

  /// Çıktının kesim çizgisi DIŞINDA gerçekten ne bıraktığını ölçer.
  ///
  /// NEDEN KUTUYU BÜYÜTMEK ZORUNDA (ölçülmüş KÖR KAPI, 2026-09-11): önceki sürüm sayfayı olduğu
  /// gibi render edip kutunun dışına bakıyordu. Ama `CGContext.drawPDFPage` sayfayı KENDİ
  /// CropBox'ına KIRPIYOR — ve kesim çıktısında CropBox tam olarak kesim kutusudur. Yani kapı,
  /// kesim payında duran içeriği HİÇ göremiyordu: "kalsın" kipiyle üretilmiş, kesim payı yerli
  /// yerinde duran bir dosyaya "temiz, %0,0" dedi. Bağımsız yolla (kutuyu qpdf ile büyüt + gs ile
  /// 300 dpi render) aynı dosyada mürekkep kutunun 8,41 pt dışına kadar ölçüldü.
  ///
  /// Doğru ölçüm: çıktının bir KOPYASINDA sayfa kutuları geçici olarak büyütülür (qpdf ile,
  /// kayıpsız), sonra render edilir. Kırpma artık ölçüm bandını kesmiyor.
  /// BANT GENİŞLİĞİ KAYNAKTAN TÜRETİLİR, sabit değildir. Sabit 8,5 pt (gerçek bir 3 mm kesim
  /// payından ölçülmüştü) 5 mm'lik ya da kenarın dış ucunda mürekkep taşıyan dosyalarda bandın
  /// DIŞINDA kalıyordu — yani kapı gerçek kalıntıyı kaçırabiliyordu (ölçüldü: 20 pt kesim paylı
  /// fixture'da mürekkep bandın tamamen dışındaydı, kapı "temiz" dedi). Doğru bant, kaynağın
  /// MediaBox'ı ile TrimBox'ı arasındaki gerçek paydır — kenar kenar.
  public static func residue(
    in output: URL, source: URL, qpdf: URL, sampleLimit: Int = 3
  ) async throws -> Result {
    guard let document = CGPDFDocument(output as CFURL), document.isUnlocked,
      document.numberOfPages > 0,
      let sourceDocument = CGPDFDocument(source as CFURL), sourceDocument.isUnlocked
    else {
      return Result(residuePercent: 100, verdict: .failed)
    }
    let count = min(document.numberOfPages, sourceDocument.numberOfPages)
    guard count > 0 else { return Result(residuePercent: 100, verdict: .failed) }
    var boxes: [Int: CGRect] = [:]
    var bleeds: [Int: CGRect] = [:]  // çıktı kutusunun kenar kenar genişletilmiş hâli
    for index in sampleIndices(count: count, limit: sampleLimit) {
      guard let page = document.page(at: index), let sourcePage = sourceDocument.page(at: index)
      else { continue }
      let box = page.getBoxRect(.mediaBox)
      guard box.width > 0, box.height > 0 else { continue }
      let sourceMedia = sourcePage.getBoxRect(.mediaBox)
      let sourceTrim = sourcePage.getBoxRect(.trimBox)
      // Kenar başına gerçek kesim payı. Çıktı kutusuna eklenir: kayıpsız kipte bu doğrudan
      // kaynağın MediaBox'ını verir; sayfayı yeniden çizen kipte içerik (0,0)'a taşındığı için
      // aynı payların çıktı kutusuna eklenmesi doğru bandı verir — iki kipte de geçerli.
      let left = max(0, sourceTrim.minX - sourceMedia.minX)
      let bottom = max(0, sourceTrim.minY - sourceMedia.minY)
      let right = max(0, sourceMedia.maxX - sourceTrim.maxX)
      let top = max(0, sourceMedia.maxY - sourceTrim.maxY)
      guard left + bottom + right + top > 0 else { continue }
      boxes[index] = box
      bleeds[index] = CGRect(
        x: box.minX - left, y: box.minY - bottom,
        width: box.width + left + right, height: box.height + bottom + top)
    }
    guard !boxes.isEmpty else { return Result(residuePercent: 100, verdict: .failed) }

    let editor = QPDFPageEditor(executable: qpdf)
    let enlarged = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.lastPathComponent).band.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: enlarged)
    defer { try? fm.removeItem(at: enlarged) }

    let ids = try await editor.pageObjectIDs(of: output)
    let (header, objects) = try await editor.pageObjects(of: output, ids: ids)
    var changed: [String: Any] = [:]
    for (index, id) in ids.enumerated() {
      guard let band = bleeds[index + 1],
        var page = QPDFPageEditor.dictionary(for: id, in: objects)
      else { continue }
      // +1 pt: bandın kenarı render sınırına DEĞMESİN, yoksa ölçümün kendisi kırpılır.
      let big = band.insetBy(dx: -1, dy: -1)
      page["/MediaBox"] = QPDFPageEditor.jsonBox(big)
      page["/CropBox"] = QPDFPageEditor.jsonBox(big)
      changed["obj:\(id)"] = ["value": page]
    }
    guard !changed.isEmpty else { return Result(residuePercent: 100, verdict: .failed) }
    try await editor.apply(update: ["qpdf": [header, changed]], to: output, output: enlarged)

    guard let enlargedDocument = CGPDFDocument(enlarged as CFURL) else {
      return Result(residuePercent: 100, verdict: .failed)
    }

    var bandPixels = 0
    var inkPixels = 0
    for (pageNumber, originalBox) in boxes {
      guard let page = enlargedDocument.page(at: pageNumber) else { continue }
      let surface = page.getBoxRect(.mediaBox)
      let scale = renderDPI / 72.0
      let width = max(1, Int((surface.width * scale).rounded(.up)))
      let height = max(1, Int((surface.height * scale).rounded(.up)))
      guard
        let ctx = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { continue }
      // Beyaz zemin: kesim payında hiçbir şey kalmadıysa bant tamamen beyaz kalır.
      ctx.setFillColor(gray: 1, alpha: 1)
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
      ctx.scaleBy(x: scale, y: scale)
      ctx.translateBy(x: -surface.origin.x, y: -surface.origin.y)
      ctx.drawPDFPage(page)
      guard let data = ctx.data else { continue }
      let bytesPerRow = ctx.bytesPerRow
      let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

      let inner = originalBox.insetBy(dx: -antialiasGuardPoints, dy: -antialiasGuardPoints)
      let outer = bleeds[pageNumber] ?? originalBox
      for row in 0..<height {
        // Satır 0 = görüntünün ÜSTÜ (en yüksek kullanıcı-uzayı y'si); bu proje içinde ölçülüp
        // doğrulandı (2026-09-07).
        let userY = surface.maxY - (Double(row) + 0.5) / Double(scale)
        let rowStart = row * bytesPerRow
        for column in 0..<width {
          let userX = surface.origin.x + (Double(column) + 0.5) / Double(scale)
          let point = CGPoint(x: userX, y: userY)
          guard outer.contains(point), !inner.contains(point) else { continue }
          bandPixels += 1
          if buffer[rowStart + column] < inkLumaThreshold { inkPixels += 1 }
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
