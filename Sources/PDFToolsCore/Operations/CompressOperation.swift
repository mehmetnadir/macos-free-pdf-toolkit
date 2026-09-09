import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `CompressOperation`'ın kendi doğrulama hatası. Yeni bir `OperationError` case'i EKLEMEK yerine
/// (bu tur `Operations/PDFOperation.swift`'e DOKUNMUYOR — kayıt/CLI/arayüz paralel başka bir
/// oturumda ilerliyor) kendi hata türü tanımlandı; `PDFOperation.run`'ın imzası (`async throws`)
/// herhangi bir `Error` fırlatılmasına izin verir, `OperationError` ZORUNLU değil.
public enum CompressError: Error, LocalizedError, Equatable {
  case verificationFailed

  public var errorDescription: String? {
    switch self {
    case .verificationFailed:
      return "Compression could not be verified (page count/content mismatch) — output deleted"
    }
  }
}

/// PDF'i üç kademeden birinde küçültür (bkz. `options`, id "level"). Ölçümler bu makinede,
/// 23,2 MB / 6 sayfalık gerçek bir matbaa dosyasıyla yapıldı (2026-09-08):
/// - "light": qpdf `--object-streams=generate --recompress-flate --compression-level=9`.
///   Kayıpsız — yalnız PDF'in İÇ paketlemesini sıkıştırır, içerik DEĞİŞMEZ. Motor HER ZAMAN var
///   (pakete gömülü qpdf). Ölçüldü: 23,2 MB → 20,4 MB (−12%), 3,1 sn.
/// - "strong": Ghostscript `-dPDFSETTINGS=/ebook`. Görüntüleri de yeniden örnekleyip sıkıştırır —
///   algısal kayıplı ama metin vektör olarak KALIR. Yalnız kullanıcının sisteminde `gs` kuruluysa
///   (bkz. `GhostscriptEngine.swift` lisans notu, `TrimOperation`'la aynı gerekçe — burada motor
///   YENİDEN SARILMAZ, yalnız `EngineLocator.trimEngine()?.executable`'dan yolu alınır, çünkü
///   `TrimEngine.trim` farklı bir `gs` çağrısı — `-dUseTrimBox` — yapar). Ölçüldü: 23,2 MB →
///   13,8 MB (−41%), 18,6 sn.
/// - "raster": harici motor YOK — CoreGraphics + ImageIO ile her sayfa JPEG'e render edilip yeni
///   bir PDF sayfasına GÖRÜNTÜ olarak çizilir. Metin katmanı KALICI OLARAK KAYBOLUR (aranabilirlik
///   gider) — çıktı `note`'unda bu HER ZAMAN belirtilir. Ölçüldü (150 dpi / kalite 0,7): 23,2 MB
///   → ~3 MB (−87%), 4,6 sn. Bellek: sayfa render edilir edilmez PDF'e yazılır, döngü içindeki
///   `ctx`/`raw`/`jpeg` yalnız o iterasyon boyunca yaşar (bkz. `ImageExportOperation`'daki aynı
///   desen) — aynı anda tek sayfalık bitmap + tek sayfalık JPEG bellekte tutulur.
public struct CompressOperation: PDFOperation {
  public static let identifier = "compress"
  public let id = CompressOperation.identifier
  public let title = "Compress"
  public let subtitle = "Makes the file smaller; the strongest level removes the text layer"
  public let systemImage = "arrow.down.circle"
  public let actionTitle = "Compress"
  public let outputSuffix = "_compressed"
  public var outputSuffixes: [String] { [outputSuffix] }

  public static let levelOptionID = "level"
  public static let dpiOptionID = "dpi"
  public static let qualityOptionID = "quality"

  /// "raster" kademesinin çıktısına HER ZAMAN eklenen uyarı — metin/aranabilirlik kaybı sessizce
  /// geçilmez.
  public static let rasterTextLossWarning = "text layer removed, no longer searchable"

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.levelOptionID, label: "Level",
        choices: [
          ("light", "Light (lossless)"),
          ("strong", "Strong (needs Ghostscript)"),
          ("raster", "Rasterize (text layer is lost)"),
        ], defaultValue: "light"),
      OperationOption(
        id: Self.dpiOptionID, label: "Resolution (Rasterize)",
        choices: [
          ("72", "72 dpi — smallest file"), ("150", "150 dpi — for screen"),
          ("200", "200 dpi — balanced"), ("300", "300 dpi — for print"),
        ],
        defaultValue: "150"),
      OperationOption(
        id: Self.qualityOptionID, label: "Quality (Rasterize)",
        choices: [
          ("0.5", "Low — smallest files"), ("0.7", "Medium — balanced"),
          ("0.85", "High — best quality, larger files"),
        ],
        defaultValue: "0.7"),
    ]
  }

  // `applicability(for:)` protokol uzantısındaki varsayılanı KULLANIR (dosya varsa
  // `.applicable(files.count)`) — görev tarifinde bu açıkça istendi, motor kontrolü (gs kurulu mu)
  // burada YAPILMAZ; "strong" kademesi seçiliyken gs yoksa hata `run()` içinde fırlatılır.

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable: throw OperationError.unreadable
    case .passwordRequired: throw OperationError.passwordRequired
    case .restricted, .none: break
    }
    guard file.pageCount > 0 else { return .skipped(reason: "No pages") }

    let level = context.options[Self.levelOptionID] ?? "light"
    let output = OutputNaming.uniqueURL(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    do {
      switch level {
      case "strong":
        // Ham gs ikilisinin yolu. `trimEngine()` ARTIK KULLANILMAZ: o kesim MOTOR TERCİHİNİ
        // döndürüyor (CoreGraphics) ve çalıştırılabilir bir ikili değil — oradan yol almak
        // sahte bir alt-süreç çağırmaya yol açardı.
        guard let gs = EngineLocator.ghostscript() else {
          throw OperationError.engineMissing("Ghostscript required: brew install ghostscript")
        }
        progress(0)
        let arguments = [
          "-q", "-o", partial.path,
          "-sDEVICE=pdfwrite",
          "-dPDFSETTINGS=/ebook",
          "-dBATCH", "-dNOPAUSE",
          file.url.path,
        ]
        let result = try await ProcessRunner.run(gs, arguments: arguments)
        guard result.status == 0 else {
          throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
        }
        progress(0.9)

      case "raster":
        guard let document = CGPDFDocument(file.url as CFURL), document.isUnlocked else {
          throw OperationError.unreadable
        }
        guard let out = CGContext(partial as CFURL, mediaBox: nil, nil) else {
          throw CompressError.verificationFailed
        }
        let dpi = CGFloat(Double(context.options[Self.dpiOptionID] ?? "150") ?? 150)
        let quality = Double(context.options[Self.qualityOptionID] ?? "0.7") ?? 0.7
        let total = document.numberOfPages
        for pageIndex in 1...total {
          try Task.checkCancellation()
          guard let page = document.page(at: pageIndex) else { continue }
          try Self.renderRasterPage(page, dpi: dpi, quality: quality, into: out)
          progress(Double(pageIndex) / Double(total))
        }
        out.closePDF()

      default:  // "light"
        guard let qpdf = EngineLocator.find("qpdf") else {
          throw OperationError.engineMissing("qpdf engine not found")
        }
        progress(0)
        let arguments = [
          "--object-streams=generate", "--recompress-flate", "--compression-level=9",
          file.url.path, partial.path,
        ]
        let result = try await ProcessRunner.run(qpdf, arguments: arguments)
        guard result.status == 0 || result.status == 3 else {
          throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
        }
        progress(0.9)
      }
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    // Kanıt 1: geçerli PDF, sayfa sayısı kaynakla AYNI (motorun sayfa düşürmediğinin kanıtı).
    guard CompressVerification.pageCountMatches(partial, expected: file.pageCount) else {
      try? fm.removeItem(at: partial)
      throw CompressError.verificationFailed
    }

    var notes: [String] = []

    if level == "raster" {
      notes.append(Self.rasterTextLossWarning)
      // Kanıt 2 (raster): sayfa BOŞ DEĞİL (beyaz olmayan piksel > eşik).
      guard
        let percent = CompressVerification.nonWhitePercent(partial),
        percent > CompressVerification.minNonWhitePercentForNonEmpty
      else {
        try? fm.removeItem(at: partial)
        throw CompressError.verificationFailed
      }
      // Kanıt 3 (raster): sayfa ölçüsü (MediaBox) korunmuş.
      guard CompressVerification.pageSizeMatches(input: file.url, output: partial) else {
        try? fm.removeItem(at: partial)
        throw CompressError.verificationFailed
      }
    } else if let sourceDoc = CGPDFDocument(file.url as CFURL), sourceDoc.isUnlocked,
      let sourcePage = sourceDoc.page(at: 1),
      CompressVerification.containsTextOperator(sourcePage)
    {
      // Kanıt 2 (light/strong): kaynak sayfa 1'de GERÇEK metin varsa çıktıda da olmalı (bkz.
      // `CompressVerification.containsTextOperator` yorumu — non-blank render kontrolü METİN ile
      // GÖRÜNTÜ arasında ayrım yapamayacağı için burada operatör taraması kullanıldı).
      guard
        let outDoc = CGPDFDocument(partial as CFURL), let outPage = outDoc.page(at: 1),
        CompressVerification.containsTextOperator(outPage)
      else {
        try? fm.removeItem(at: partial)
        throw CompressError.verificationFailed
      }
    }

    // Kanıt 4: çıktı kaynaktan küçük mü? Değilse ÇIKTIYI SİLME — kullanıcıya `note` ile bildir
    // (sıkıştırma bazen büyütür, bunu sessizce "başarılı" saymak yanıltıcı olur).
    let sizeResult = CompressVerification.compareSize(input: file.url, output: partial)
    if sizeResult.verdict == .notSmaller {
      notes.append(
        "output didn't shrink (\(sizeResult.outputBytes) bytes ≥ \(sizeResult.inputBytes) "
        + "bytes source)")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: notes.isEmpty ? nil : notes.joined(separator: " · "))
  }

  /// Tek sayfayı `dpi`'de render edip JPEG'e (`quality`) sıkıştırır, sonra o JPEG'i `out`'un yeni
  /// bir sayfasına görüntü olarak çizer. Bilinçli olarak `run()`'ın DÖNGÜSÜ İÇİNDEN çağrılır (bkz.
  /// `ImageExportOperation.renderPage` aynı desen): burada yerel olan `ctx`/`raw`/`jpegData`/`jpeg`
  /// yalnız bu çağrı boyunca yaşar, bir sonraki sayfaya geçmeden ARC ile serbest kalır.
  private static func renderRasterPage(
    _ page: CGPDFPage, dpi: CGFloat, quality: Double, into out: CGContext
  ) throws {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { throw CompressError.verificationFailed }
    let scale = dpi / 72.0
    let width = max(1, Int((box.width * scale).rounded()))
    let height = max(1, Int((box.height * scale).rounded()))
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw CompressError.verificationFailed }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let raw = ctx.makeImage() else { throw CompressError.verificationFailed }

    let jpegData = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        jpegData, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw CompressError.verificationFailed }
    CGImageDestinationAddImage(
      destination, raw, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CompressError.verificationFailed }
    guard
      let jpegSource = CGImageSourceCreateWithData(jpegData, nil),
      let jpeg = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)
    else { throw CompressError.verificationFailed }

    var mediaBox = CGRect(x: 0, y: 0, width: box.width, height: box.height)
    out.beginPage(mediaBox: &mediaBox)
    out.draw(jpeg, in: mediaBox)
    out.endPage()
  }
}
