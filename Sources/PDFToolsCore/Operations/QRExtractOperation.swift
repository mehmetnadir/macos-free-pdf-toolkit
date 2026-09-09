import CoreGraphics
import Foundation

/// Bir PDF'teki QR kodlarını sayfa sayfa listeler. Motor: Apple Vision, `QRVerification` üzerinden
/// (harici bağımlılık YOK — bkz. o dosyanın tip yorumu). Çıktı PDF DEĞİL — `<ad>_qr.txt` metin
/// dosyası, her satır `sayfa\tiçerik` biçiminde (1-tabanlı sayfa numarası + TAB + çözülen metin).
///
/// ÖLÇÜLMÜŞ KRİTİK BULGU (bkz. `QRVerification` tip yorumu, gerçek üretim kitabı
/// https://yds.tc/ydsdigital): Vision'ın QR tespiti 100 dpi'da bu kitapta SESSİZCE 0 QR buldu —
/// "QR yok" ile "bakılamadı" ayırt edilemez sonuç. Bu yüzden varsayılan 200 dpi'dır ve seçeneklerde
/// 100 dpi HİÇ sunulmaz. Sonuç notunda ("N sayfada M QR bulundu") ve `.skipped` mesajında
/// ("bulunamadı" ile "bakılmadı" karışmasın diye) TARANAN sayfa sayısı da bulunur.
///
/// Bellek: büyük kitaplarda (200+ sayfa) sayfa başına TEK render bitmap tutulur — döngü içindeki
/// `QRVerification.detections` çağrısının sonucu bir sonraki sayfaya geçmeden ARC ile serbest kalır
/// (bkz. `ImageExportOperation`'daki aynı karar).
public struct QRExtractOperation: PDFOperation {
  public static let identifier = "qrextract"
  public let id = QRExtractOperation.identifier
  public let title = "Extract QR"
  public let subtitle = "Lists the QR codes on the pages and writes them to a text file"
  public let systemImage = "qrcode.viewfinder"
  public let actionTitle = "Extract QR"

  public static let dpiOptionID = "dpi"

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.dpiOptionID, label: "Resolution",
        choices: [
          ("150", "150 dpi — faster"), ("200", "200 dpi — recommended"),
          ("300", "300 dpi — most accurate"),
        ],
        defaultValue: "200"),
    ]
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable: throw OperationError.unreadable
    case .passwordRequired: throw OperationError.passwordRequired
    case .restricted, .none: break
    }
    guard file.pageCount > 0 else {
      return .skipped(reason: "No pages (0 pages scanned)")
    }

    let dpi = CGFloat(Double(context.options[Self.dpiOptionID] ?? "200") ?? 200)
    guard let document = CGPDFDocument(file.url as CFURL), document.isUnlocked else {
      throw OperationError.unreadable
    }
    let total = document.numberOfPages

    var lines: [String] = []
    var found = 0
    for pageIndex in 1...total {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex) else { continue }
      let payloads = QRVerification.detectedPayloads(onPage: page, dpi: dpi)
      for payload in payloads {
        lines.append("\(pageIndex)\t\(payload)")
        found += 1
      }
      progress(Double(pageIndex) / Double(total))
    }

    guard found > 0 else {
      return .skipped(reason: "No QR codes found (\(total) pages scanned)")
    }

    let output = Self.uniqueTextOutputURL(for: file.url, in: context.outputDirectory)
    let text = lines.joined(separator: "\n") + "\n"
    guard let data = text.data(using: .utf8) else {
      throw QRError.generationFailed
    }
    try data.write(to: output, options: .atomic)
    progress(1)
    return .produced(urls: [output], note: "Found \(found) QR codes across \(total) pages")
  }

  /// `<ad>_qr.txt` biçiminde, çakışmaya karşı korumalı bir çıktı yolu üretir.
  /// `OutputNaming.uniqueURL` KULLANILMADI: o fonksiyon uzantıyı HER ZAMAN girdiden (pdf) miras
  /// alır (bkz. tip yorumu), burada ise sabit ".txt" gerekiyor — bu yüzden aynı çakışma-önleme
  /// mantığı burada, girdiye dokunmadan, yerel olarak tekrarlanıyor.
  private static func uniqueTextOutputURL(for input: URL, in directory: URL?) -> URL {
    let dir = directory ?? input.deletingLastPathComponent()
    let stem = input.deletingPathExtension().lastPathComponent + "_qr"
    let fm = FileManager.default
    var candidate = dir.appendingPathComponent(stem).appendingPathExtension("txt")
    var counter = 2
    while fm.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent("\(stem) \(counter)").appendingPathExtension("txt")
      counter += 1
    }
    return candidate
  }
}
