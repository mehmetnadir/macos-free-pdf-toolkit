import CoreGraphics
import Foundation
import Vision

/// Taranmış (metin katmanı olmayan) bir PDF'in sayfalarını Apple'ın yerleşik Vision çerçevesiyle
/// (`VNRecognizeTextRequest`, bkz. `OCRVerification.recognizeText`) okuyup düz metin dosyasına
/// aktarır. Harici motor YOK, model indirme YOK, API anahtarı YOK. Sayfa sayfa render + tanıma
/// yapılır — döngü içinde her seferinde TEK sayfalık görüntü bellekte tutulur, bir sonraki sayfaya
/// geçmeden serbest kalır (bkz. `ImageExportOperation` ile AYNI gerekçe) — 200+ sayfalık bir
/// kitapta bellek patlamaz. Çıktı: `<ad>_ocr.txt`, sayfalar `--- page N ---` ayracıyla ayrılır.
///
/// ÖLÇÜLMÜŞ ZEMİN VE BİLİNEN HATA: bkz. `OCRVerification` dosya üstü yorumu — Türkçede noktalı
/// büyük İ bazen noktasız I okunuyor. Bu yüzden Türkçe seçiliyken `note`'ta AÇIK bir uyarı var;
/// "OCR yaptım, metin hazır" gibi kesin bir dil KULLANILMAZ.
public struct OCROperation: PDFOperation {
  public static let identifier = "ocr"
  public let id = OCROperation.identifier
  public let title = "OCR"
  public let subtitle = "Reads scanned pages with Vision and converts them to plain text"
  public let systemImage = "text.viewfinder"
  public let actionTitle = "Run OCR"

  public static let languageOptionID = "language"
  public static let dpiOptionID = "dpi"
  public static let levelOptionID = "level"

  /// `language` seçeneğinin Vision'a geçilecek `recognitionLanguages` karşılığı. `OCROperation` ve
  /// `SearchablePDFOperation`'IN PAYLAŞTIĞI TEK kaynak — seçenek listeleri de burada tanımlı,
  /// `SearchablePDFOperation.options` buradan okur (kopya YOK).
  public static let recognitionLanguages: [String: [String]] = [
    "tr": ["tr-TR"], "en": ["en-US"], "auto": ["tr-TR", "en-US"],
  ]
  public static let languageChoices: [(value: String, label: String)] = [
    ("tr", "Turkish"), ("en", "English"), ("auto", "Automatic (TR + EN)"),
  ]
  public static let dpiChoices: [(value: String, label: String)] = [
    ("150", "150 dpi — faster"), ("200", "200 dpi — recommended"),
    ("300", "300 dpi — most accurate"),
  ]

  /// `OCRVerification.turkishSupportDegraded` true dönerse gösterilen uyarı — `OCROperation` ve
  /// `SearchablePDFOperation`'IN PAYLAŞTIĞI TEK metin (bkz. dosya üstü CI ölçümü, 2026-09-08).
  public static let turkishSupportWarning =
    "Turkish language support was not found on this Mac; the text was read with an English "
    + "model and Turkish characters may be wrong."

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.languageOptionID, label: "Language", choices: Self.languageChoices,
        defaultValue: "tr"),
      OperationOption(
        id: Self.dpiOptionID, label: "Resolution", choices: Self.dpiChoices, defaultValue: "200"),
      OperationOption(
        id: Self.levelOptionID, label: "Quality",
        choices: [("accurate", "Accurate (slower)"), ("fast", "Fast")], defaultValue: "accurate"),
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
    guard let document = CGPDFDocument(file.url as CFURL), document.isUnlocked else {
      throw OperationError.unreadable
    }
    let total = document.numberOfPages
    guard total > 0 else { return .skipped(reason: "No pages") }

    let languageKey = context.options[Self.languageOptionID] ?? "tr"
    let languages = Self.recognitionLanguages[languageKey] ?? Self.recognitionLanguages["tr"]!
    let dpi = CGFloat(Double(context.options[Self.dpiOptionID] ?? "200") ?? 200)
    let levelValue = context.options[Self.levelOptionID] ?? "accurate"
    let level: VNRequestTextRecognitionLevel = levelValue == "fast" ? .fast : .accurate

    // Dosyada zaten metin katmanı var mı — `note`'ta ayrıca uyarılır (bkz. aşağı).
    let hasExistingTextLayer = OCRVerification.hasExistingTextLayer(at: file.url)

    var pageBlocks: [String] = []
    var confidences: [Float] = []
    pageBlocks.reserveCapacity(total)

    for pageIndex in 1...total {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex) else { continue }
      let lines = try OCRVerification.recognizeText(
        onPage: page, dpi: dpi, languages: languages, level: level)
      pageBlocks.append(lines.map(\.text).joined(separator: "\n"))
      confidences.append(contentsOf: lines.map(\.confidence))
      progress(Double(pageIndex) / Double(total) * 0.9)
    }

    guard !confidences.isEmpty else {
      return .skipped(reason: "No text recognized (\(total) pages scanned)")
    }

    let combined = Self.combine(pageBlocks)
    let output = Self.uniqueTextURL(for: file.url, suffix: "_ocr", in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.txt")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)
    do {
      try combined.write(to: partial, atomically: true, encoding: .utf8)
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }
    progress(0.95)

    // Kanıt: çıktı dosyası GERÇEKTEN boş değil (`ExtractTextOperation` ile AYNI gerekçe — yazma
    // sırasında sessiz bir kesilme olmadığından emin olmak için diskten geri okunuyor, bellekteki
    // `combined`'a güvenilmiyor).
    guard
      let written = try? String(contentsOf: partial, encoding: .utf8),
      !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      try? fm.removeItem(at: partial)
      throw OCRError.verificationFailed("output file is empty")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)

    let avgConfidence = confidences.reduce(0, +) / Float(confidences.count)
    var noteParts = [
      "\(total) pages, \(confidences.count) lines, average confidence "
        + String(format: "%.2f", avgConfidence)
    ]
    let requestsTurkish = languageKey == "tr" || languageKey == "auto"
    if requestsTurkish {
      // İKİ BAĞIMSIZ sinyal — bkz. `OCRVerification.turkishSupportDegraded` dosya üstü CI ölçümü:
      // bu makinede Vision'ın tr-TR'ye sessizce düşmediğinden emin olunamıyorsa, ya da GERÇEK
      // çıktıda hiç Türkçe aksanlı harf yoksa, kesin bir "OCR yaptım" dili YERİNE açık uyarı verilir.
      if OCRVerification.turkishSupportDegraded(level: level, recognizedText: combined) {
        noteParts.append(Self.turkishSupportWarning)
      }
      noteParts.append(
        "In Turkish text, capital İ is sometimes read as I — review critical text carefully.")
    }
    if hasExistingTextLayer {
      noteParts.append(
        "This file already has a text layer — 'Extract Text' gives a more accurate result.")
    }
    return .produced(urls: [output], note: noteParts.joined(separator: " "))
  }

  /// Sayfalar arasına `--- page N ---` ayracı koyar (N: takip eden sayfanın numarası) — görev
  /// tanımındaki sabit biçim, `ExtractTextOperation`'ın "pages" kipiyle BENZER mantık (OCR'da
  /// biçim seçimi YOK, hep ayraçlı).
  static func combine(_ pageTexts: [String]) -> String {
    guard !pageTexts.isEmpty else { return "" }
    var parts: [String] = []
    parts.reserveCapacity(pageTexts.count)
    for (index, text) in pageTexts.enumerated() {
      parts.append("--- page \(index + 1) ---\n\(text)")
    }
    return parts.joined(separator: "\n\n")
  }

  /// `ExtractTextOperation.uniqueTextURL` ile AYNI desen, yalnız bir `suffix` parametresi eklendi
  /// — o dosyaya dokunulmuyor (bkz. görev kısıtları), bu yüzden burada bağımsız küçük bir kopya.
  private static func uniqueTextURL(for input: URL, suffix: String, in directory: URL?) -> URL {
    let dir = directory ?? input.deletingLastPathComponent()
    let stem = input.deletingPathExtension().lastPathComponent + suffix
    var candidate = dir.appendingPathComponent(stem).appendingPathExtension("txt")
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent("\(stem) \(counter)").appendingPathExtension("txt")
      counter += 1
    }
    return candidate
  }
}

/// `OCROperation`'a özgü hatalar — `OperationError`'a EKLENMEDİ (bkz. `QRError`/`ExtractTextError`
/// ile AYNI desen: işleme özgü hata kendi dosyasında).
public enum OCRError: Error, LocalizedError, Equatable {
  /// Yazılan metin dosyası boş çıktı; çıktı silinir, işlem hata döner.
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .verificationFailed(let detail):
      return "OCR output could not be verified — \(detail) — output deleted"
    }
  }
}
