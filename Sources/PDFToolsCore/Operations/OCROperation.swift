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
  public var outputSuffixes: [String] { ["_ocr"] }
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
        choices: [("accurate", "Accurate (slower)"), ("fast", "Fast (less accurate)")],
        defaultValue: "accurate"),
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

    // Sayfa numarasından metne — DİZİ DEĞİL (bkz. `combine` yorumu): bir sayfa açılamayıp
    // atlanırsa dizi kayıp sonraki TÜM sayfaları yanlış numarayla etiketlemesin diye.
    var pageBlocks: [Int: String] = [:]
    var confidences: [Float] = []
    var unopenedPages: [Int] = []
    pageBlocks.reserveCapacity(total)

    for pageIndex in 1...total {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex) else {
        // SESSİZCE YUTULMAZ (bkz. dosya üstü yorum, 2026-09-29 sessiz-hata denetimi) — sayfa
        // numarası `pageBlocks`'a hiç girmez, `combine` boş bırakıp ayracı yine de basar, ve
        // kullanıcıya `note`'ta AÇIKÇA bildirilir (bkz. aşağı).
        unopenedPages.append(pageIndex)
        continue
      }
      let lines = try OCRVerification.recognizeText(
        onPage: page, dpi: dpi, languages: languages, level: level)
      pageBlocks[pageIndex] = lines.map(\.text).joined(separator: "\n")
      confidences.append(contentsOf: lines.map(\.confidence))
      progress(Double(pageIndex) / Double(total) * 0.9)
    }

    guard !confidences.isEmpty else {
      return .skipped(reason: "No text recognized — pages may be blank or too low quality to read")
    }

    let combined = Self.combine(pageBlocks, total: total)
    let output = Self.uniqueTextURL(for: file.url, suffix: "_ocr", in: context.outputDirectory)
    let fm = FileManager.default
    // GÜVENLİK: Swift'in KENDİSİ veri yazıyor (metin dosyası) — `TempArtifact.writeExclusive`
    // ile `O_EXCL|O_NOFOLLOW|O_CREAT` korumalı, benzersiz bir dosyaya yazılıyor (bkz. o tipin
    // gerekçesi).
    let partial = try TempArtifact.writeExclusive(
      Data(combined.utf8), in: output.deletingLastPathComponent(), suffix: ".part.txt")
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

    // Ham güven skoru (0...1) kullanıcıya bir şey ifade etmez — üç anlamlı kovaya çevrilir (bkz.
    // görev tanımı: "engine'in ölçtüğünü değil kullanıcının belgesine olanı raporla").
    let avgConfidence = confidences.reduce(0, +) / Float(confidences.count)
    var noteParts: [String]
    if avgConfidence < 0.6 {
      noteParts = ["Text recognized — accuracy is low, review carefully"]
    } else if avgConfidence < 0.85 {
      noteParts = ["Text recognized — some words may be misread"]
    } else {
      noteParts = ["Text recognized"]
    }
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
    // SESSİZCE YUTULMAZ (bkz. `run()` döngüsü ve `unopenedPagesNote` yorumu): bir sayfa
    // açılamadıysa kullanıcı bunu NOT satırından öğrenir, sonuç metninden sessizce kaybolmaz.
    if let unopenedNote = Self.unopenedPagesNote(unopenedPages) {
      noteParts.append(unopenedNote)
    }
    return .produced(urls: [output], note: noteParts.joined(separator: " "))
  }

  /// Sayfalar arasına `--- page N ---` ayracı koyar; `N` GERÇEK sayfa numarasıdır — `pages`
  /// sözlüğünde bir anahtar EKSİKSE (bkz. `run()`: `document.page(at:)` o sayfa için `nil` döndü)
  /// yalnız o sayfanın METNİ boş kalır, ayracın numarası KAYMAZ. ESKİ hata (2026-09-29 sessiz-hata
  /// denetimi): girdi düz bir diziydi ve atlanan sayfa dizide DELİK bırakmıyordu — bu yüzden
  /// atlanan sayfadan SONRAKİ TÜM sayfalar bir numara KÜÇÜK etiketleniyordu (`combine`'ı doğrudan
  /// sınayan `OCRCombineTests.testSkippedPageDoesNotShiftSubsequentPageNumbers` bu regresyonu
  /// mutasyonla kanıtlıyor).
  static func combine(_ pages: [Int: String], total: Int) -> String {
    guard total > 0 else { return "" }
    var parts: [String] = []
    parts.reserveCapacity(total)
    for pageNumber in 1...total {
      parts.append("--- page \(pageNumber) ---\n\(pages[pageNumber] ?? "")")
    }
    return parts.joined(separator: "\n\n")
  }

  /// `unopenedPages` boşsa `nil` — sayfaları SIRALI, insan-okur listeye çevirir. Sayfa numaraları
  /// gömülü olduğu için `BookmarkOperation`'ın "Exported N bookmarks" notuyla AYNI gerekçeyle bu
  /// metin Türkçe tabloda TAM DİZGE eşleşmesi BULAMAZ (bkz. `Localization.swift` tasarım kararı:
  /// anahtar İngilizce kaynağın KENDİSİ) — kabul edilmiş, mevcut bir sınır, bu turun kapsamı DEĞİL.
  static func unopenedPagesNote(_ unopenedPages: [Int]) -> String? {
    guard !unopenedPages.isEmpty else { return nil }
    let list = unopenedPages.sorted().map(String.init).joined(separator: ", ")
    return "Page(s) \(list) could not be opened and were skipped — page numbers for the "
      + "remaining pages are unaffected."
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
