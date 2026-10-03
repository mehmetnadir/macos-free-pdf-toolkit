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
/// `VNRecognizedText.boundingBox(for:)` istenir (alınamazsa satır kutusu). Kelime, kutusunun
/// genişliğine `textMatrix` yatay ölçeğiyle sığdırılır; böylece seçim dikdörtgeni basılı kelimenin
/// üstüne düşer. Satırın son kelimesi dışındaki her kelimenin SONUNA bir boşluk glifi eklenir
/// (genişlik hesabına katılmadan) — eklenmezse metin çıkarıcılar kelimeleri birleştiriyor
/// (prototipte ölçüldü: pdftotext "Gruplar ve" → "Gruplarve").
public enum OCRTextLayer {
  public enum Resolution: Sendable, Equatable {
    /// Sayfadaki en büyük gömülü görüntünün piksel genişliği / MediaBox genişliği
    /// (1 pt = 1 px → 1.0).
    /// Görüntü yoksa `fallbackDPI/72`. Sonuç [0.5, 6.0] aralığına kırpılır.
    case native(fallbackDPI: CGFloat)
    case dpi(CGFloat)
  }

  public struct PageStats: Sendable {
    public let pageIndex: Int  // 1 tabanlı
    public let lines: Int
    public let words: Int
    public let meanConfidence: Double  // kelime yoksa 0
    public let renderScale: CGFloat
    public let sampleText: String?  // ilk boş olmayan SATIR (doğrulama kapısı girdisi)
  }

  public struct Result: Sendable {
    public let pages: [PageStats]
    public let sawTurkishDiacritic: Bool
    public var totalWords: Int { pages.reduce(0) { $0 + $1.words } }
    public var pagesWithoutText: [Int] { pages.filter { $0.words == 0 }.map(\.pageIndex) }
  }

  /// `.native` ölçeğin alt/üst sınırı — dev bir görüntü bitmap'i patlatmasın, minicik bir
  /// küçük resim de Vision'a okunamaz bir bitmap vermesin.
  static let scaleRange: ClosedRange<CGFloat> = 0.5...6.0

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
    switch resolution {
    case .dpi(let dpi):
      return dpi / 72
    case .native(let fallbackDPI):
      let box = page.getBoxRect(.mediaBox)
      let raw: CGFloat
      if box.width > 0, let pixels = nativeImageWidth(of: page) {
        raw = CGFloat(pixels) / box.width
      } else {
        raw = fallbackDPI / 72
      }
      return min(max(raw, scaleRange.lowerBound), scaleRange.upperBound)
    }
  }

  /// Bir kelimenin (ya da kutusu alınamamış parçanın) normalize kutusu ve metni.
  struct Word {
    let text: String
    let box: CGRect  // normalize, orijin SOL-ALT
    let confidence: Float
    let endsLine: Bool
  }

  /// Vision gözlemlerini kelimelere böler (bkz. dosya üstü "KELİME KUTULARI").
  static func words(from observations: [VNRecognizedTextObservation]) -> (
    words: [Word], lines: Int, sample: String?, sawTurkish: Bool
  ) {
    var words: [Word] = []
    var lines = 0
    var sample: String?
    var sawTurkish = false
    for observation in observations {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let string = candidate.string
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      lines += 1
      if sample == nil { sample = trimmed }
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
        let box =
          (try? candidate.boundingBox(for: index..<end))?.boundingBox ?? observation.boundingBox
        lineWords.append(
          Word(
            text: String(string[index..<end]), box: box, confidence: candidate.confidence,
            endsLine: false))
        index = end
      }
      if let last = lineWords.popLast() {
        lineWords.append(
          Word(text: last.text, box: last.box, confidence: last.confidence, endsLine: true))
      }
      words.append(contentsOf: lineWords)
    }
    return (words, lines, sample, sawTurkish)
  }

  /// Normalize kelime kutusunu sayfa uzayına çevirip kelimeyi görünmez çizer.
  static func drawInvisible(_ word: Word, pageBox: CGRect, into ctx: CGContext) {
    let rect = CGRect(
      x: pageBox.minX + word.box.minX * pageBox.width,
      y: pageBox.minY + word.box.minY * pageBox.height,
      width: word.box.width * pageBox.width,
      height: word.box.height * pageBox.height)
    guard rect.width > 0, rect.height > 0 else { return }
    let fontSize = max(2, rect.height * 0.8)
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let attrs = [kCTFontAttributeName: font] as CFDictionary
    guard let wordString = CFAttributedStringCreate(nil, word.text as CFString, attrs) else {
      return
    }
    // Genişlik YALNIZ kelimeden ölçülür; çizilen satıra (satır sonu değilse) boşluk eklenir.
    let natural = CTLineGetTypographicBounds(
      CTLineCreateWithAttributedString(wordString), nil, nil, nil)
    let drawnText = word.endsLine ? word.text : word.text + " "
    guard let drawnString = CFAttributedStringCreate(nil, drawnText as CFString, attrs) else {
      return
    }
    let line = CTLineCreateWithAttributedString(drawnString)
    let scaleX = natural > 0 ? rect.width / CGFloat(natural) : 1
    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    ctx.textMatrix = CGAffineTransform(scaleX: scaleX, y: 1)
    ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }

  /// `document`un HER sayfası için aynı MediaBox'lı, YALNIZ görünmez metin içeren bir sayfa yazar.
  /// Kelime kutuları: satır adayını boşluklardan böl, her parça için `boundingBox(for:)`;
  /// alınamazsa satır kutusu. Punto = kutu yüksekliği×0,8 (min 2). Yatay ölçek `textMatrix` ile
  /// kutu genişliğine sığdırılır (CTLineGetTypographicBounds). Font: Helvetica (CTFontCreateWithName). Çizim kipi
  /// `.invisible`. Sayfa başına TEK bitmap bellekte (döngü içinde yaşar).
  /// Sayfa açılamazsa (`page(at:) == nil`) FIRLATIR (sessiz `continue` YASAK — eksik sayfa kapısı).
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
        let observations = try OCRVerification.recognizeObservations(
          onPage: page, scale: scale, languages: languages, level: level)
        let split = words(from: observations)
        if split.sawTurkish { sawTurkish = true }

        let pageInfo = boxInfo(for: page)
        ctx.beginPDFPage(pageInfo as CFDictionary)
        let mediaBox = page.getBoxRect(.mediaBox)
        for word in split.words { drawInvisible(word, pageBox: mediaBox, into: ctx) }
        ctx.endPDFPage()

        let confidenceSum = split.words.reduce(0.0) { $0 + Double($1.confidence) }
        return PageStats(
          pageIndex: pageIndex, lines: split.lines, words: split.words.count,
          meanConfidence: split.words.isEmpty ? 0 : confidenceSum / Double(split.words.count),
          renderScale: scale, sampleText: split.sample)
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
  /// (açı başına bir argüman, sayfalar virgülle). Döndürülmüş sayfa yoksa boş.
  ///
  /// NEDEN (ölçüldü 2026-10-03, qpdf 12.4.1): `--overlay` hem kaynağın içeriğini hem katmanı
  /// Form XObject'e sarar; her formun `/Matrix`'i KENDİ sayfasının dönüşünü taşır, yerleştirme de
  /// HEDEF sayfanın dönüşünü tersine çevirir. Kaynak `/Rotate 90` iken içeriğin net dönüşümü birim
  /// matris çıkıyor, ama dönüşsüz katman için qpdf `0 0.754 -0.754 0 2709 773.7 cm` uyguladı —
  /// katman döndürülüp küçültülüyor, kelime kutuları basılı kelimeden kopuyordu. Katman sayfasına
  /// kaynakla AYNI `/Rotate` verilince iki form aynı `0 1 -1 0 2709 0 cm`'yi alıyor ve net
  /// dönüşüm yine birim matris oluyor. CGPDFContext `/Rotate` yazamadığı için bu adım qpdf ile.
  public static func rotationArguments(for document: CGPDFDocument) -> [String] {
    var pagesByAngle: [Int: [Int]] = [:]
    for index in stride(from: 1, through: document.numberOfPages, by: 1) {
      guard let page = document.page(at: index) else { continue }
      let angle = ((Int(page.rotationAngle) % 360) + 360) % 360
      if angle != 0 { pagesByAngle[angle, default: []].append(index) }
    }
    return pagesByAngle.keys.sorted().map { angle in
      let pages = pagesByAngle[angle, default: []].map(String.init).joined(separator: ",")
      return "--rotate=+\(angle):\(pages)"
    }
  }
}
