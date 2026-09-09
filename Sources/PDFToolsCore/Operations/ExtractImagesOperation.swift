import CoreGraphics
import Foundation

/// Sayfalardaki gömülü görselleri ayrı dosyalara çıkarır. Motor: pdfcpu `images extract`
/// (paketli, Apache-2.0) — CGPDFStream/CGPDFDictionary API'leriyle ELLE ayrıştırma YERİNE. Gerekçe:
/// bu API'ler (`CGPDFDictionaryGetDictionary`, `CGPDFStreamCopyData`, `CGPDFDataFormat.raw` /
/// `.jpegEncoded` vb.) gerçekten var ve çalışıyor — bir deneme programıyla doğrulandı — ama yalnızca
/// basit DeviceRGB/DeviceGray + DCTDecode görsellerini güvenle kapsıyor. Bu araç kutusunun hedef
/// kullanım alanındaki gerçek dosyalarda (taranmış kitap sayfaları, baskıya hazır CMYK/ICC dosyalar)
/// görseller Indexed/ICCBased/CMYK/SMask-alfa gibi PDF görüntü modelinin tam kapsamını gerektirebilir;
/// bunları elle ayrıştırmak SESSİZCE renk-bozuk ya da yanlış bir görsel üretme riski taşır — bu proje
/// genelinde "gerçek piksele bak, motora güvenme" ilkesine ters düşerdi. pdfcpu bu tam modeli zaten
/// doğru uyguluyor ve bu depoda başka işlemlerde (Birleştir/Parçala) hâlâ vendored + test edilmiş
/// durumda; ek bir motor/lisans riski yok. Çıktı: `<ad>_embedded/` klasörü — pdfcpu'nun kendi
/// `<taban>_<sayfa>_<isim>.<uzantı>` adlandırması korunur; yalnızca "minSize" eşiğinin altında kalan
/// (ikon/çizgi gibi) görseller elenir.
public struct ExtractImagesOperation: PDFOperation {
  public static let identifier = "extractimages"
  public let id = ExtractImagesOperation.identifier
  public let title = "Extract Embedded Images"
  public let subtitle = "Exports each embedded image on the pages to its own file"
  public let systemImage = "photo.stack"
  public let actionTitle = "Extract Embedded Images"
  public let outputSuffix = "_embedded"

  public static let minSizeOptionID = "minSize"

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.minSizeOptionID, label: "Minimum Size",
        choices: [("0", "All"), ("10000", "Larger than 10,000 px")],
        defaultValue: "10000"),
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
    guard let pdfcpu = EngineLocator.find("pdfcpu") else {
      throw OperationError.engineMissing("pdfcpu engine not found")
    }
    let minSize = Int(context.options[Self.minSizeOptionID] ?? "10000") ?? 10000

    let outputDir = OutputNaming.uniqueDirectory(
      for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partialDir = outputDir.deletingLastPathComponent()
      .appendingPathComponent(".\(outputDir.lastPathComponent).part", isDirectory: true)
    let fm = FileManager.default
    try? fm.removeItem(at: partialDir)
    // pdfcpu hedef klasörü KENDİSİ oluşturmuyor (ölçülüp doğrulandı) — Parçala/Görüntüye Aktar'daki
    // gibi burada da önceden oluşturuluyor.
    try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)

    progress(0)
    do {
      let result = try await ProcessRunner.run(
        pdfcpu, arguments: ["images", "extract", file.url.path, partialDir.path])
      guard result.status == 0 else {
        throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
      }
    } catch is CancellationError {
      try? fm.removeItem(at: partialDir)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partialDir)
      throw error
    }
    progress(0.7)

    let extracted =
      (try? fm.contentsOfDirectory(at: partialDir, includingPropertiesForKeys: nil)) ?? []
    var kept: [URL] = []
    for url in extracted {
      // Kanıt: her dosya GERÇEKTEN açılabilir bir görüntü olmalı (bkz. ImageExportVerification) —
      // açılamayan bir dosya elenir, minSize eşiği piksel alanına göre uygulanır.
      guard let result = ImageExportVerification.inspect(url) else {
        try? fm.removeItem(at: url)
        continue
      }
      if result.width * result.height >= minSize {
        kept.append(url)
      } else {
        try? fm.removeItem(at: url)
      }
    }

    guard !kept.isEmpty else {
      try? fm.removeItem(at: partialDir)
      return .skipped(reason: "No embedded images found")
    }

    try fm.moveItem(at: partialDir, to: outputDir)
    progress(1)
    let finalOutputs =
      kept.map { outputDir.appendingPathComponent($0.lastPathComponent) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    return .produced(urls: finalOutputs, note: nil)
  }
}
