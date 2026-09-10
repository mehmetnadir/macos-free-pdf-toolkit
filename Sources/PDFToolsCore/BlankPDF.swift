import CoreGraphics
import Foundation

/// Sayfa boyutu — punto (pt) cinsinden. `standard` listesindeki tüm boyutlar mm/inch'ten
/// TÜRETİLİR (sabit yuvarlanmış punto değeri gömülmez), böylece dönüşüm formülü TEK yerde durur.
public struct PageSize: Sendable, Equatable {
  public let name: String
  public let width: Double
  public let height: Double

  public init(name: String, width: Double, height: Double) {
    self.name = name
    self.width = width
    self.height = height
  }

  /// mm → punto: `mm * 72 / 25.4`. Yuvarlama YOK — çağıran istediği hassasiyette kullanır.
  private static func pointsFromMillimeters(_ mm: Double) -> Double {
    mm * 72.0 / 25.4
  }

  public static let a4 = PageSize(
    name: "A4", width: pointsFromMillimeters(210), height: pointsFromMillimeters(297))
  public static let a5 = PageSize(
    name: "A5", width: pointsFromMillimeters(148), height: pointsFromMillimeters(210))
  public static let a3 = PageSize(
    name: "A3", width: pointsFromMillimeters(297), height: pointsFromMillimeters(420))
  public static let letter = PageSize(name: "Letter", width: 612, height: 792)
  public static let legal = PageSize(name: "Legal", width: 612, height: 1008)
  public static let tabloid = PageSize(name: "Tabloid", width: 792, height: 1224)

  /// Arayüzde seçim listesi bu sırayla gösterilecek; A4 ilk.
  public static let standard: [PageSize] = [a4, a5, a3, letter, legal, tabloid]

  /// Milimetreden üretir (kullanıcı kendi ölçüsünü girer).
  public static func custom(widthMM: Double, heightMM: Double) -> PageSize {
    PageSize(
      name: "Custom", width: pointsFromMillimeters(widthMM),
      height: pointsFromMillimeters(heightMM))
  }

  /// En/boy takas edilmiş kopya. Adı da değişsin (ör. "A4" → "A4 landscape").
  public func landscape() -> PageSize {
    PageSize(name: "\(name) landscape", width: height, height: width)
  }
}

public enum BlankPDFError: Error, LocalizedError, Equatable {
  case invalidPageCount
  case invalidPageSize
  case writeFailed
  /// Yazıldı ama yeniden açınca beklenen çıkmadı (sayfa sayısı ya da MediaBox uyuşmuyor).
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidPageCount:
      return "Page count must be at least 1"
    case .invalidPageSize:
      return "Page width and height must both be greater than zero"
    case .writeFailed:
      return "Could not write the output file (it may already exist, or the destination is not writable)"
    case .verificationFailed(let reason):
      return "Output could not be verified after writing — \(reason)"
    }
  }
}

/// Boş (içeriksiz) PDF üretimi — girdi dosyası YOK, bu yüzden bir `PDFOperation` DEĞİL.
public enum BlankPDF {
  /// `pageCount` sayfalık boş PDF yazar. Önce gizli bir geçici dosyaya yazar, dosyayı yeniden
  /// AÇIP sayfa sayısını ve 1. sayfanın MediaBox'ını doğrular, tutmuyorsa `.verificationFailed`
  /// fırlatır ve yarım çıktıyı bırakmaz. `overwrite: false` (varsayılan) iken hedefte zaten bir
  /// dosya varsa üstüne YAZMAZ, `.writeFailed` fırlatır — mevcut dosya OLDUĞU GİBİ kalır.
  /// `overwrite: true` iken de doğrulama BAŞARILI olmadan eski dosyaya dokunulmaz (yarım çıktı
  /// uğruna sağlam dosya kaybedilmez): geçici dosya doğrulanır, ANCAK ONDAN SONRA hedefe taşınır.
  public static func create(
    pageCount: Int, size: PageSize, at url: URL, overwrite: Bool = false
  ) throws {
    try create(
      pageCount: pageCount, size: size, at: url, overwrite: overwrite,
      pagesToWrite: pageCount)
  }

  /// `pagesToWrite` YALNIZ testler için ayrılmıştır: kasten eksik sayfa yazdırıp
  /// doğrulamanın GERÇEKTEN çağrıldığını kanıtlamayı mümkün kılar. Public API'de görünmez ve
  /// bir global bayrak DEĞİLDİR — varsayılan yol her zaman `pageCount` geçirir, yanlışlıkla
  /// "açık kalması" mümkün değil (ilk yazımdaki `debugForcePageCountShortfall` static'i
  /// tam da bu riski taşıyordu: açık unutulursa kullanıcıya sessizce eksik sayfalı dosya).
  static func create(
    pageCount: Int, size: PageSize, at url: URL, overwrite: Bool = false,
    pagesToWrite: Int
  ) throws {
    guard pageCount >= 1 else { throw BlankPDFError.invalidPageCount }
    guard size.width > 0, size.height > 0 else { throw BlankPDFError.invalidPageSize }

    let fm = FileManager.default
    let destinationExists = fm.fileExists(atPath: url.path)
    if destinationExists && !overwrite {
      throw BlankPDFError.writeFailed
    }

    // Depodaki diğer işlemlerin deseni (bkz. `UnlockOperation`): önce gizli `.part.pdf`'e yaz,
    // doğrulama geçince TEK `moveItem` ile son ada.
    let partial = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).part.pdf")
    try? fm.removeItem(at: partial)

    var mediaBox = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    guard let consumer = CGDataConsumer(url: partial as CFURL) else {
      try? fm.removeItem(at: partial)
      throw BlankPDFError.writeFailed
    }
    guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      try? fm.removeItem(at: partial)
      throw BlankPDFError.writeFailed
    }

    // `kCGPDFContextMediaBox` değeri "CFData containing a CGRect, by value" olmalı — `NSValue`
    // sessizce yok sayılır (bkz. `CoreGraphicsTrimEngine` yorumu, ölçüldü). Her sayfa AYNI kutuyu
    // kullanıyor ama context başlatma sırasına GÜVENMEK yerine her `beginPDFPage`'e açıkça
    // veriyoruz — sayfa sayısı arttıkça (250) davranış hâlâ garanti kalsın diye.
    var pageBox = mediaBox
    let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
    let pageInfo = [kCGPDFContextMediaBox as String: boxData as CFData] as CFDictionary

    for _ in 0..<pagesToWrite {
      try Task.checkCancellation()
      ctx.beginPDFPage(pageInfo)
      // Sayfa GERÇEKTEN boş: hiçbir içerik çizilmiyor.
      ctx.endPDFPage()
    }
    ctx.closePDF()

    // Kanıt: dosyayı yeniden aç ve ölç. Motorun/API'nin "yazdım" demesine güvenilmez.
    do {
      try verify(partial, expectedPages: pageCount, expectedSize: size)
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    if overwrite && destinationExists {
      try? fm.removeItem(at: url)
    }
    do {
      try fm.moveItem(at: partial, to: url)
    } catch {
      try? fm.removeItem(at: partial)
      throw BlankPDFError.writeFailed
    }
  }

  /// Yazılan dosyayı yeniden açıp beklenen sayfa sayısı ve sayfa kutusuyla karşılaştırır.
  ///
  /// `create`'ten AYRI bir fonksiyon olması bilinçli: doğrulamanın kendisi, üretim koduna
  /// bir test anahtarı koymadan sınanabilsin diye. (İlk yazımında `create` bir
  /// `debugForcePageCountShortfall` bayrağına göre dallanıyordu; üretim kodunda öyle bir
  /// anahtar, yanlışlıkla açık kalırsa kullanıcıya sessizce eksik sayfalı dosya üretir —
  /// tam da bu doğrulamanın önlemeye çalıştığı şey.) Test kasten YANLIŞ beklenti vererek
  /// bu fonksiyonun gerçekten yakaladığını kanıtlar.
  static func verify(_ url: URL, expectedPages: Int, expectedSize: PageSize) throws {
    guard let document = CGPDFDocument(url as CFURL) else {
      throw BlankPDFError.verificationFailed("output could not be reopened as a PDF")
    }
    guard document.numberOfPages == expectedPages else {
      throw BlankPDFError.verificationFailed(
        "expected \(expectedPages) pages, got \(document.numberOfPages)")
    }
    guard let firstPage = document.page(at: 1) else {
      throw BlankPDFError.verificationFailed("first page could not be read back")
    }
    let box = firstPage.getBoxRect(.mediaBox)
    guard abs(Double(box.width) - expectedSize.width) < 0.01,
      abs(Double(box.height) - expectedSize.height) < 0.01
    else {
      throw BlankPDFError.verificationFailed(
        "expected \(expectedSize.width)x\(expectedSize.height) pt, "
          + "got \(box.width)x\(box.height) pt")
    }
  }
}
