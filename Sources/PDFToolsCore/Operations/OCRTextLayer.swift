import CoreGraphics
import CoreText
import Foundation
import Vision

/// "Aranabilir Yap"ın kayıpsız (`overlay`) kipinin katman üreticisi: kaynağın HER sayfası için
/// AYNI sayfa kutularına sahip, YALNIZ görünmez (`Tr 3`) metin içeren bir sayfa yazar. Bu katman
/// sonra `qpdf --overlay` ile kaynağın üstüne bindirilir — kaynak sayfa hiç yeniden ÇİZİLMEZ,
/// görüntü baytları ve pikseller birebir kalır (spec: `.claude/docs/aranabilir-katman-spec.md`).
///
/// ÖLÇÜLMÜŞ ZEMİN (prototip, 2026-10-03, gerçek kitap sayfaları — 2709×3591 px tek JPEG,
/// MediaBox 1 pt = 1 px): Vision `.accurate` tr-TR+en-US, yerel ölçekte (1.0) 0,4–0,9 sn/sayfa,
/// ortalama güven 0,985–0,993. 150 dpi'a büyütmek (2,08×) kelime sayısını DEĞİŞTİRMEDİ, süreyi
/// %60 artırdı — bu yüzden varsayılan çözünürlük görüntünün KENDİ çözünürlüğü (`.native`).
///
/// KELİME KUTULARI: Vision satır adayı boşluklardan bölünür, her parça için
/// `VNRecognizedText.boundingBox(for:)` istenir (alınamazsa satır kutusu). Kutunun KÖŞELERİ
/// kullanılır, eksen hizalı dikdörtgeni değil: Vision 90/180/270° dönük metni de okuyor ve
/// köşeler metnin yönünü taşıyor (ölçüldü 2026-10-03: 90° metinde sol-alt→sağ-alt +y yönünde).
/// Kelime o açıyla, taban çizgisi uzunluğuna `textMatrix` yatay ölçeğiyle sığdırılarak çizilir;
/// böylece hem yan taranmış sayfada hem kitap içindeki yan tablolarda seçim basılı kelimenin
/// üstüne düşer. Satırın son kelimesi dışındaki her kelimenin SONUNA bir boşluk glifi eklenir
/// (genişlik hesabına katılmadan) — eklenmezse metin çıkarıcılar kelimeleri birleştiriyor
/// (prototipte ölçüldü: pdftotext "Gruplar ve" → "Gruplarve").
public enum OCRTextLayer {
  public enum Resolution: Sendable, Equatable {
    /// Sayfadaki en büyük gömülü görüntünün piksel genişliği / MediaBox genişliği
    /// (1 pt = 1 px → 1.0). Görüntü yoksa `fallbackDPI/72`.
    /// Sonuç (her iki durumda da) [0.5, 6.0] aralığına kırpılır.
    case native(fallbackDPI: CGFloat)
    case dpi(CGFloat)
  }

  public struct PageStats: Sendable {
    public let pageIndex: Int  // 1 tabanlı
    public let lines: Int
    /// Katmana GERÇEKTEN çizilen kelimeler (sıfır boyutlu kutular hariç).
    public let words: Int
    public let meanConfidence: Double  // kelime yoksa 0
    public let renderScale: CGFloat
    /// En uzun SATIR (doğrulama kapısı girdisi — uzun satır yanlış konumu daha iyi yakalar).
    public let sampleText: String?
    /// `sampleText` satırının sayfa uzayındaki (MediaBox, orijin SOL-ALT) eksen hizalı kutusu.
    public let sampleRect: CGRect?
  }

  public struct Result: Sendable {
    public let pages: [PageStats]
    public let sawTurkishDiacritic: Bool
    public var totalWords: Int { pages.reduce(0) { $0 + $1.words } }
    public var pagesWithoutText: [Int] { pages.filter { $0.words == 0 }.map(\.pageIndex) }
  }

  /// Render ölçeğinin alt/üst sınırı — dev bir görüntü (ya da `--dpi 100000`) bitmap'i
  /// patlatmasın, minicik bir küçük resim de Vision'a okunamaz bir bitmap vermesin.
  static let scaleRange: ClosedRange<CGFloat> = 0.5...6.0
  /// Açı bir dik açının bu kadar yakınındaysa dik açıya oturtulur (Vision köşe gürültüsü).
  static let angleSnap: CGFloat = 1 * .pi / 180

  /// Sayfadaki (ve kullandığı formlardaki) en geniş gömülü görüntünün piksel genişliği.
  public static func nativeImageWidth(of page: CGPDFPage) -> Int? {
    var best = 0
    PDFImageIdentity.forEachImageStream(in: page) { stream in
      guard let dict = CGPDFStreamGetDictionary(stream) else { return }
      var width: CGPDFInteger = 0
      if CGPDFDictionaryGetInteger(dict, "Width", &width) { best = max(best, Int(width)) }
    }
    return best > 0 ? best : nil
  }

  public static func renderScale(for page: CGPDFPage, resolution: Resolution) -> CGFloat {
    let raw: CGFloat
    switch resolution {
    case .dpi(let dpi):
      raw = dpi / 72
    case .native(let fallbackDPI):
      let box = page.getBoxRect(.mediaBox)
      if box.width > 0, let pixels = nativeImageWidth(of: page) {
        raw = CGFloat(pixels) / box.width
      } else {
        raw = fallbackDPI / 72
      }
    }
    // NaN/sonsuz/aşırı değer bitmap kurulurken süreci çökertiyordu (inceleme 2026-10-03:
    // `--dpi inf` → SIGTRAP, `--dpi 100000` → SIGKILL) — her yolda kırpılır.
    guard raw.isFinite else { return raw.isNaN ? 1 : scaleRange.upperBound }
    return min(max(raw, scaleRange.lowerBound), scaleRange.upperBound)
  }

  /// Bir kelimenin (ya da kutusu alınamamış parçanın) normalize köşeleri (orijin SOL-ALT) ve metni.
  struct Word {
    let text: String
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
    let topLeft: CGPoint
    let confidence: Float
    let endsLine: Bool
  }

  /// Satır bilgisi: kelimeleri + metni (örnek satır seçimi için).
  struct Line {
    let text: String
    let words: [Word]
  }

  /// Vision gözlemlerini satır/kelimelere böler (bkz. dosya üstü "KELİME KUTULARI").
  static func lines(from observations: [VNRecognizedTextObservation]) -> (
    lines: [Line], sawTurkish: Bool
  ) {
    var lines: [Line] = []
    var sawTurkish = false
    for observation in observations {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let string = candidate.string
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if !sawTurkish, OCRVerification.containsTurkishDiacritic(trimmed) { sawTurkish = true }
      var lineWords: [Word] = []
      var index = string.startIndex
      while index < string.endIndex {
        while index < string.endIndex, string[index].isWhitespace {
          index = string.index(after: index)
        }
        guard index < string.endIndex else { break }
        var end = index
        while end < string.endIndex, !string[end].isWhitespace { end = string.index(after: end) }
        let quad: VNRectangleObservation =
          ((try? candidate.boundingBox(for: index..<end)) ?? nil) ?? observation
        lineWords.append(
          Word(
            text: String(string[index..<end]), bottomLeft: quad.bottomLeft,
            bottomRight: quad.bottomRight, topLeft: quad.topLeft,
            confidence: candidate.confidence, endsLine: false))
        index = end
      }
      if let last = lineWords.popLast() {
        lineWords.append(
          Word(
            text: last.text, bottomLeft: last.bottomLeft, bottomRight: last.bottomRight,
            topLeft: last.topLeft, confidence: last.confidence, endsLine: true))
      }
      lines.append(Line(text: trimmed, words: lineWords))
    }
    return (lines, sawTurkish)
  }

  /// Bir kelimenin sayfa uzayındaki yerleşimi: taban çizgisi başlangıcı, açı, uzunluk, yükseklik.
  struct Placement {
    let origin: CGPoint
    let angle: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// Dört köşeyi kapsayan eksen hizalı kutu (seçim/doğrulama için).
    let bounds: CGRect
  }

  static func placement(of word: Word, pageBox: CGRect) -> Placement? {
    func map(_ point: CGPoint) -> CGPoint {
      CGPoint(
        x: pageBox.minX + point.x * pageBox.width, y: pageBox.minY + point.y * pageBox.height)
    }
    let bottomLeft = map(word.bottomLeft)
    let bottomRight = map(word.bottomRight)
    let topLeft = map(word.topLeft)
    let baseline = CGVector(dx: bottomRight.x - bottomLeft.x, dy: bottomRight.y - bottomLeft.y)
    let side = CGVector(dx: topLeft.x - bottomLeft.x, dy: topLeft.y - bottomLeft.y)
    let width = hypot(baseline.dx, baseline.dy)
    let height = hypot(side.dx, side.dy)
    guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
    var angle = atan2(baseline.dy, baseline.dx)
    let quarter = CGFloat.pi / 2
    let nearest = (angle / quarter).rounded() * quarter
    if abs(angle - nearest) < angleSnap { angle = nearest }
    let topRight = CGPoint(x: bottomRight.x + side.dx, y: bottomRight.y + side.dy)
    let xs = [bottomLeft.x, bottomRight.x, topLeft.x, topRight.x]
    let ys = [bottomLeft.y, bottomRight.y, topLeft.y, topRight.y]
    let bounds = CGRect(
      x: xs.min() ?? 0, y: ys.min() ?? 0,
      width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    return Placement(
      origin: bottomLeft, angle: angle, width: width, height: height, bounds: bounds)
  }

  /// Kelimeyi görünmez çizer; sıfır boyutlu kutuda ÇİZMEZ ve `nil` döner (sayılmasın diye).
  @discardableResult
  static func drawInvisible(_ word: Word, pageBox: CGRect, into ctx: CGContext) -> Placement? {
    guard let place = placement(of: word, pageBox: pageBox) else { return nil }
    let fontSize = max(2, place.height * 0.8)
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let attrs = [kCTFontAttributeName: font] as CFDictionary
    guard let wordString = CFAttributedStringCreate(nil, word.text as CFString, attrs) else {
      return nil
    }
    // Genişlik YALNIZ kelimeden ölçülür; çizilen satıra (satır sonu değilse) boşluk eklenir.
    let natural = CTLineGetTypographicBounds(
      CTLineCreateWithAttributedString(wordString), nil, nil, nil)
    let drawnText = word.endsLine ? word.text : word.text + " "
    guard let drawnString = CFAttributedStringCreate(nil, drawnText as CFString, attrs) else {
      return nil
    }
    let line = CTLineCreateWithAttributedString(drawnString)
    let scaleX = natural > 0 ? place.width / CGFloat(natural) : 1
    // Taban çizgisi kutunun altından yüksekliğin %15'i kadar yukarıda (inen harfler için pay);
    // "yukarı" kelimenin kendi yönüne diktir.
    let lift = place.height * 0.15
    let position = CGPoint(
      x: place.origin.x - sin(place.angle) * lift, y: place.origin.y + cos(place.angle) * lift)
    // Döndürme `textMatrix`'e değil CTM'e konur: CTLineDraw dönük bir metin matrisinde glif
    // konumlarını bozuyor (ölçüldü: 90° kelimeden PDFKit yalnız "M" okudu).
    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    ctx.translateBy(x: position.x, y: position.y)
    if place.angle != 0 { ctx.rotate(by: place.angle) }
    ctx.textMatrix = CGAffineTransform(scaleX: scaleX, y: 1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    return place
  }

  /// `document`un HER sayfası için aynı MediaBox'lı, YALNIZ görünmez metin içeren bir sayfa yazar.
  /// Kelime kutuları: satır adayını boşluklardan böl, her parça için `boundingBox(for:)`;
  /// alınamazsa satır kutusu. Punto = kutu yüksekliği×0,8 (min 2). Yatay ölçek `textMatrix` ile
  /// kutu genişliğine sığdırılır (CTLineGetTypographicBounds); açı kutu köşelerinden.
  /// Font: Helvetica (CTFontCreateWithName). Çizim kipi `.invisible`. Sayfa başına TEK bitmap
  /// bellekte (döngü içinde yaşar).
  /// Sayfa açılamazsa ya da render EDİLEMEZSE FIRLATIR (`pageUnreadable`) — "ölçemedim" boş sayfa
  /// sayılmaz (sessiz `continue` YASAK — eksik sayfa kapısı).
  ///
  /// Kırpma/taşma/kesim kutuları da kaynaktan kopyalanır: `qpdf --overlay` katmanı kaynağın
  /// kutusuna YERLEŞTİRİRKEN iki tarafın kutularını eşler; kutular aynıysa dönüşüm birim matristir
  /// (ölçüldü), farklıysa katman ölçeklenip kayardı.
  public static func write(
    document: CGPDFDocument, to url: URL, languages: [String], resolution: Resolution,
    level: VNRequestTextRecognitionLevel = .accurate,
    progress: @escaping @Sendable (Double) -> Void
  ) throws -> Result {
    let total = document.numberOfPages
    var dummyBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let ctx = CGContext(consumer: consumer, mediaBox: &dummyBox, nil)
    else { throw SearchablePDFError.generationFailed }

    var stats: [PageStats] = []
    stats.reserveCapacity(total)
    var sawTurkish = false
    var closed = false
    defer { if !closed { ctx.closePDF() } }

    for pageIndex in stride(from: 1, through: total, by: 1) {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex) else {
        throw SearchablePDFError.pageUnreadable(page: pageIndex)
      }
      let pageStats: PageStats = try autoreleasepool {
        let scale = renderScale(for: page, resolution: resolution)
        // Bitmap yalnız bu kapanış boyunca yaşar — aynı anda TEK sayfalık görüntü bellekte.
        let observations: [VNRecognizedTextObservation]
        do {
          observations = try OCRVerification.recognizeObservations(
            onPage: page, scale: scale, languages: languages, level: level)
        } catch is OCRVerification.RenderError {
          throw SearchablePDFError.pageUnreadable(page: pageIndex)
        }
        let split = lines(from: observations)
        if split.sawTurkish { sawTurkish = true }

        ctx.beginPDFPage(boxInfo(for: page) as CFDictionary)
        let mediaBox = page.getBoxRect(.mediaBox)
        var drawn = 0
        var confidenceSum = 0.0
        var sample: (text: String, rect: CGRect)?
        for line in split.lines {
          var lineRect: CGRect?
          for word in line.words {
            guard let place = drawInvisible(word, pageBox: mediaBox, into: ctx) else { continue }
            drawn += 1
            confidenceSum += Double(word.confidence)
            lineRect = lineRect.map { $0.union(place.bounds) } ?? place.bounds
          }
          if let lineRect, line.text.count > (sample?.text.count ?? 0) {
            sample = (line.text, lineRect)
          }
        }
        ctx.endPDFPage()

        return PageStats(
          pageIndex: pageIndex, lines: split.lines.count, words: drawn,
          meanConfidence: drawn == 0 ? 0 : confidenceSum / Double(drawn),
          renderScale: scale, sampleText: sample?.text, sampleRect: sample?.rect)
      }
      stats.append(pageStats)
      progress(Double(pageIndex) / Double(max(total, 1)))
    }
    ctx.closePDF()
    closed = true
    return Result(pages: stats, sawTurkishDiacritic: sawTurkish)
  }

  /// Kaynak sayfanın beş kutusunu CGPDFContext sayfa bilgisine çevirir.
  private static func boxInfo(for page: CGPDFPage) -> [CFString: Any] {
    func data(_ rect: CGRect) -> CFData {
      var copy = rect
      return Data(bytes: &copy, count: MemoryLayout<CGRect>.size) as CFData
    }
    return [
      kCGPDFContextMediaBox: data(page.getBoxRect(.mediaBox)),
      kCGPDFContextCropBox: data(page.getBoxRect(.cropBox)),
      kCGPDFContextBleedBox: data(page.getBoxRect(.bleedBox)),
      kCGPDFContextTrimBox: data(page.getBoxRect(.trimBox)),
      kCGPDFContextArtBox: data(page.getBoxRect(.artBox)),
    ]
  }

  /// `/Rotate`'i 0 olmayan sayfalar için katmana uygulanacak qpdf `--rotate` argümanları
  /// (açı başına bir argüman, sayfalar virgülle). Döndürülmüş sayfa yoksa boş. Açılamayan sayfa
  /// FIRLATIR (atlanırsa o sayfanın katmanı telafisiz kalırdı).
  ///
  /// NEDEN (ölçüldü 2026-10-03, qpdf 12.4.1): `--overlay` hem kaynağın içeriğini hem katmanı
  /// Form XObject'e sarar; her formun `/Matrix`'i KENDİ sayfasının dönüşünü taşır, yerleştirme de
  /// HEDEF sayfanın dönüşünü tersine çevirir. Kaynak `/Rotate 90` iken içeriğin net dönüşümü birim
  /// matris çıkıyor, ama dönüşsüz katman için qpdf `0 0.754 -0.754 0 2709 773.7 cm` uyguladı —
  /// katman döndürülüp küçültülüyor, kelime kutuları basılı kelimeden kopuyordu. Katman sayfasına
  /// kaynakla AYNI `/Rotate` verilince iki form aynı `0 1 -1 0 2709 0 cm`'yi alıyor ve net
  /// dönüşüm yine birim matris oluyor. CGPDFContext `/Rotate` yazamadığı için bu adım qpdf ile.
  public static func rotationArguments(for document: CGPDFDocument) throws -> [String] {
    var pagesByAngle: [Int: [Int]] = [:]
    for index in stride(from: 1, through: document.numberOfPages, by: 1) {
      guard let page = document.page(at: index) else {
        throw SearchablePDFError.pageUnreadable(page: index)
      }
      let angle = ((Int(page.rotationAngle) % 360) + 360) % 360
      if angle != 0 { pagesByAngle[angle, default: []].append(index) }
    }
    return pagesByAngle.keys.sorted().map { angle in
      let pages = pagesByAngle[angle, default: []].map(String.init).joined(separator: ",")
      return "--rotate=+\(angle):\(pages)"
    }
  }
}
