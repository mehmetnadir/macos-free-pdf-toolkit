import CoreGraphics
import Foundation
import ImageIO

/// Görüntü biçimi seçenekleri. WebP burada YOK: bu makinede `CGImageDestinationCopyTypeIdentifiers()`
/// ile ölçüldü — ImageIO WebP'yi OKUYABİLİYOR ama YAZAMIYOR (bkz. `ImageExportOperation.heicSupported`
/// ile aynı tür çalışma-anı kontrolü; WebP hiç seçenek olarak sunulmuyor çünkü hiçbir Apple Silicon
/// Mac'te ImageIO WebP encoder'ı yok — brew'deki `cwebp` yalnızca Intel).
enum ImageFormat: String, Sendable {
  case png, jpeg, heic

  var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

  /// ImageIO'nun `CGImageDestinationCreateWithURL` için beklediği UTI dizgesi.
  var uti: String {
    switch self {
    case .png: return "public.png"
    case .jpeg: return "public.jpeg"
    case .heic: return "public.heic"
    }
  }
}

/// Her sayfayı görüntü dosyasına yazar. Yalnızca yerleşik CoreGraphics + ImageIO kullanılır —
/// alt süreç YOK. Çıktılar `<ad>_images/` klasörüne `page-001.png` gibi yazılır.
/// Bellek: sayfa render edilir edilmez diske yazılır, aynı anda tek sayfalık bitmap tutulur.
public struct ImageExportOperation: PDFOperation {
  public static let identifier = "image"
  public let id = ImageExportOperation.identifier
  public let title = "PDF to Images"
  public let subtitle = "Converts each page to a PNG/JPEG/HEIC image"
  public let systemImage = "photo.on.rectangle"
  public let actionTitle = "PDF to Images"
  public let outputSuffix = "_images"
  public var outputSuffixes: [String] { [outputSuffix] }

  public static let formatOptionID = "format"
  public static let dpiOptionID = "dpi"

  public init() {}

  /// HEIC yazma desteği bu sistemde var mı — ÇALIŞMA ANINDA kontrol edilir (bkz. dosya üstü
  /// yorum). Statik/sabit varsayılmaz; farklı bir macOS/donanımda sonuç değişebilir.
  static var heicWriteSupported: Bool {
    guard let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] else { return false }
    return identifiers.contains(ImageFormat.heic.uti)
  }

  public var options: [OperationOption] {
    var formatChoices: [(value: String, label: String)] = [
      ("png", "PNG — lossless, larger files"), ("jpeg", "JPEG — smaller files, some quality loss"),
    ]
    if Self.heicWriteSupported {
      formatChoices.append(("heic", "HEIC — smallest files, needs newer viewers"))
    }
    return [
      OperationOption(
        id: Self.formatOptionID, label: "Format", choices: formatChoices, defaultValue: "png"),
      OperationOption(
        id: Self.dpiOptionID, label: "Resolution",
        choices: [
          ("72", "72 dpi — web preview"), ("150", "150 dpi — for screen"),
          ("300", "300 dpi — for print"), ("600", "600 dpi — high-res print"),
        ],
        defaultValue: "150"),
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
      return .skipped(reason: "No pages")
    }

    let formatValue = context.options[Self.formatOptionID] ?? "png"
    guard let format = ImageFormat(rawValue: formatValue) else {
      throw OperationError.unsupportedOperationMode("Unknown image format: \(formatValue)")
    }
    if format == .heic, !Self.heicWriteSupported {
      throw OperationError.engineMissing("HEIC writing isn't supported on this system")
    }
    let dpi = CGFloat(Double(context.options[Self.dpiOptionID] ?? "150") ?? 150)

    guard let document = CGPDFDocument(file.url as CFURL), document.isUnlocked else {
      throw OperationError.unreadable
    }
    let total = document.numberOfPages

    let outputDir = OutputNaming.uniqueDirectory(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partialDir = outputDir.deletingLastPathComponent()
      .appendingPathComponent(".\(outputDir.lastPathComponent).part", isDirectory: true)
    let fm = FileManager.default
    try? fm.removeItem(at: partialDir)
    try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)

    var outputs: [URL] = []
    do {
      for pageIndex in 1...total {
        try Task.checkCancellation()
        guard let page = document.page(at: pageIndex) else { continue }
        let name = "page-" + String(format: "%03d", pageIndex) + "." + format.fileExtension
        let pageURL = partialDir.appendingPathComponent(name)
        // Bilinçli olarak DÖNGÜ İÇİNDE: context/image/destination yalnızca bu iterasyon boyunca
        // yaşar, bir sonraki sayfaya geçmeden ARC ile serbest kalır — aynı anda tek sayfa bellekte.
        try Self.renderPage(page, dpi: dpi, format: format, to: pageURL)
        outputs.append(pageURL)
        progress(Double(pageIndex) / Double(total))
      }
    } catch is CancellationError {
      try? fm.removeItem(at: partialDir)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partialDir)
      throw error
    }

    // Kanıt: üretilen dosya sayısı == sayfa sayısı. Piksel boyutu ve "boş değil" ölçümü
    // `ImageExportVerification` ile testlerde yapılır (her sayfada tek tek koşmak, meşru şekilde
    // boş bırakılmış bir kaynak sayfayı hataymış gibi reddedebileceğinden burada zorunlu değil).
    guard outputs.count == total else {
      try? fm.removeItem(at: partialDir)
      throw OperationError.imageExportVerificationFailed
    }

    try fm.moveItem(at: partialDir, to: outputDir)
    let finalOutputs = outputs.map { outputDir.appendingPathComponent($0.lastPathComponent) }
    return .produced(urls: finalOutputs, note: nil)
  }

  private static func renderPage(_ page: CGPDFPage, dpi: CGFloat, format: ImageFormat, to url: URL) throws {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { throw OperationError.imageExportVerificationFailed }
    let scale = dpi / 72.0
    let width = max(1, Int((box.width * scale).rounded(.up)))
    let height = max(1, Int((box.height * scale).rounded(.up)))
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw OperationError.imageExportVerificationFailed }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let image = ctx.makeImage() else { throw OperationError.imageExportVerificationFailed }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.uti as CFString, 1, nil) else {
      throw OperationError.imageExportVerificationFailed
    }
    var properties: [CFString: Any] = [:]
    if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.92 }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw OperationError.imageExportVerificationFailed }
  }
}
