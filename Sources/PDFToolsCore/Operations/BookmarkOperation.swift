import CoreGraphics
import Foundation

/// Bir PDF'in yer imlerini (doküman anahattı / outline) dışa aktarır ya da bir JSON'dan içe
/// aktarır. Motor: yalnız pdfcpu — `bookmarks export`/`bookmarks import` alt komutları GERÇEK
/// ikili ile denenerek DOĞRULANDI (`vendor/bin/pdfcpu bookmarks export|import --help` + gerçek
/// dosyalarla deneme, 2026-09-08):
///
/// - JSON ŞEMASI (üretim koduna güvenmeden, ölçülerek bulundu — `--help` bunu YAZMIYOR):
///   pdfcpu'nun kendi `export` çıktısı `{"header": {...}, "bookmarks": [{"title": "...",
///   "page": N, "kids": [...]}]}` biçiminde; `kids` iç içe (recursive) alt yer imleri taşır.
///   `import` yalnızca `{"bookmarks": [...]}` gövdesini zorunlu kılıyor — düz bir dizi (`[...]`)
///   ya da "header"sız farklı bir sarmalayıcı DENENDİ ve ikisi de `"invalid bookmark JSON"`
///   hatasıyla reddedildi; yalnız `{"bookmarks": [...]}` (header'sız da olabilir) kabul edildi.
/// - `import`, HEDEF dosyada zaten yer imi VARSA `--replace` bayrağı OLMADAN "existing bookmarks"
///   hatasıyla BAŞARISIZ oluyor (ölçüldü); bu yüzden bu işlem HER ZAMAN `--replace` geçer —
///   kaynakta yer imi yoksa bunun bir etkisi yok (ölçüldü, aynı sonucu veriyor), varsa
///   kullanıcının verdiği JSON'un TAMAMEN geçerli olması beklenir (kısmi birleştirme YOK, JSON
///   tüm ağacı tanımlar).
/// - `export`, kaynakta HİÇ yer imi yoksa exit kodu 1 ile "export bookmarks: ...: no bookmarks
///   available" verir ve HİÇBİR dosya YAZMAZ (ölçüldü) — bu, `.skipped(reason:)` kararı için
///   güvenilir bir sinyal.
///
/// Doğrulama motora (pdfcpu) güvenmez — bkz. `BookmarkVerification`: dışa aktarımda pdfcpu'nun
/// JSON'da bildirdiği sayı PDFKit'in KENDİ okuduğu `outlineRoot` sayısıyla, içe aktarımda ise
/// çıktının PDFKit sayımı JSON'daki (girdi) sayıyla karşılaştırılır — ikisi de BAĞIMSIZ bir
/// ikinci ölçüm.
public struct BookmarkOperation: PDFOperation {
  public static let identifier = "bookmarks"
  public let id = BookmarkOperation.identifier
  public let title = "Bookmarks"
  public let subtitle = "Exports bookmarks, or imports them from a JSON file"
  public let systemImage = "bookmark"
  public let actionTitle = "Apply Bookmarks"

  public static let modeOptionID = "mode"
  /// `OperationContext.options` anahtarı: içe aktarılacak JSON'un dosya yolu — serbest bir yol
  /// olduğundan (bkz. `QRAddOperation.contentOptionID` aynı gerekçe) bir `OperationOption` DEĞİL.
  public static let bookmarkFileOptionID = "bookmarkFile"

  public static let exportSuffix = "_bookmarks"
  public static let importSuffix = "_bookmarked"
  public var outputSuffixes: [String] { [Self.exportSuffix, Self.importSuffix] }

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.modeOptionID, label: "Mode",
        choices: [
          ("export", "Export — save bookmarks to a JSON file"),
          ("import", "Import — apply bookmarks from a JSON file"),
        ], defaultValue: "export")
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
    let mode = context.options[Self.modeOptionID] ?? "export"
    if mode == "import" {
      return try await runImport(file: file, context: context, pdfcpu: pdfcpu, progress: progress)
    }
    return try await runExport(file: file, context: context, pdfcpu: pdfcpu, progress: progress)
  }

  // MARK: - Dışa aktar

  private func runExport(
    file: PDFFileInfo, context: OperationContext, pdfcpu: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    let output = Self.uniqueJSONURL(
      for: file.url, suffix: Self.exportSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.json")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    progress(0)
    let result = try await ProcessRunner.run(
      pdfcpu, arguments: ["bookmarks", "export", file.url.path, partial.path])
    guard result.status == 0 else {
      try? fm.removeItem(at: partial)
      let combined = (result.stderr + result.stdout).lowercased()
      if combined.contains("no bookmarks available") {
        return .skipped(reason: "No bookmarks to export")
      }
      throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
    }
    progress(0.6)

    // Kanıt 1: JSON geçerli ve ayrıştırılabilir.
    guard let data = try? Data(contentsOf: partial),
      let decoded = try? JSONDecoder().decode(BookmarkFile.self, from: data)
    else {
      try? fm.removeItem(at: partial)
      throw BookmarkError.verificationFailed("exported JSON could not be read")
    }
    let exportedCount = Self.countEntries(decoded.bookmarks)

    // Kanıt 2: pdfcpu'nun JSON'da bildirdiği sayı, PDFKit'in KENDİ okuduğu outline sayısıyla
    // uyuşuyor mu — motora güvenilmiyor (bkz. dosya üstü yorum).
    let outlineCount = BookmarkVerification.outlineCount(file.url)
    guard exportedCount == outlineCount, exportedCount > 0 else {
      try? fm.removeItem(at: partial)
      throw BookmarkError.verificationFailed(
        "bookmark count mismatch (JSON: \(exportedCount), PDFKit: \(outlineCount))")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: "Exported \(exportedCount) bookmarks")
  }

  // MARK: - İçe aktar

  private func runImport(
    file: PDFFileInfo, context: OperationContext, pdfcpu: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    guard let bookmarkPath = context.options[Self.bookmarkFileOptionID], !bookmarkPath.isEmpty
    else {
      throw BookmarkError.fileRequired
    }
    let jsonURL = URL(fileURLWithPath: bookmarkPath)
    guard let data = try? Data(contentsOf: jsonURL),
      let decoded = try? JSONDecoder().decode(BookmarkFile.self, from: data)
    else {
      throw BookmarkError.invalidFile
    }
    let expectedCount = Self.countEntries(decoded.bookmarks)
    guard expectedCount > 0 else { throw BookmarkError.invalidFile }

    let output = OutputNaming.uniqueURL(
      for: file.url, suffix: Self.importSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    progress(0)
    // `--replace` HER ZAMAN geçilir — bkz. dosya üstü yorum: hedefte zaten yer imi varsa bu bayrak
    // olmadan pdfcpu "existing bookmarks" ile başarısız oluyor (ölçüldü).
    let result = try await ProcessRunner.run(
      pdfcpu,
      arguments: ["bookmarks", "import", "--replace", file.url.path, jsonURL.path, partial.path])
    guard result.status == 0 else {
      try? fm.removeItem(at: partial)
      throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
    }
    progress(0.7)

    // Kanıt 1: sayfa sayısı korunmuş.
    guard let doc = CGPDFDocument(partial as CFURL), doc.numberOfPages == file.pageCount else {
      try? fm.removeItem(at: partial)
      throw BookmarkError.verificationFailed("page count wasn't preserved")
    }

    // Kanıt 2: çıktıdaki yer imi sayısı JSON'daki (girdi) ile eşit — PDFKit `outlineRoot` üzerinden
    // BAĞIMSIZ bir sayım, pdfcpu'nun kendisine güvenilmiyor.
    let actualCount = BookmarkVerification.outlineCount(partial)
    guard actualCount == expectedCount else {
      try? fm.removeItem(at: partial)
      throw BookmarkError.verificationFailed(
        "bookmark count mismatch (expected: \(expectedCount), output: \(actualCount))")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: "Applied \(actualCount) bookmarks")
  }

  /// İç içe (kids) dahil TÜM giriş sayısını sayar — export/import doğrulamasının PAYLAŞTIĞI sayaç.
  static func countEntries(_ entries: [BookmarkFile.Entry]) -> Int {
    entries.reduce(0) { $0 + 1 + countEntries($1.kids ?? []) }
  }

  /// `ExtractTextOperation.uniqueTextURL`/`QRExtractOperation` ile AYNI gerekçe: JSON çıktısı
  /// `.pdf` uzantısını KORUYAN `OutputNaming.uniqueURL` ile üretilemez (o her zaman girdinin
  /// uzantısını kullanır), bu yüzden küçük, işleme özel bir adlandırma yardımcısı.
  private static func uniqueJSONURL(for input: URL, suffix: String, in directory: URL?) -> URL {
    let dir = directory ?? input.deletingLastPathComponent()
    let stem = input.deletingPathExtension().lastPathComponent + suffix
    var candidate = dir.appendingPathComponent(stem).appendingPathExtension("json")
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent("\(stem) \(counter)").appendingPathExtension("json")
      counter += 1
    }
    return candidate
  }
}

/// pdfcpu'nun yer imi JSON şeması — yalnız `import` için ZORUNLU olan `bookmarks` alanı modellenir;
/// pdfcpu'nun kendi `export` çıktısındaki `header` alanı (kaynak/sürüm/üretim zamanı) bilerek
/// ATLANIR, `JSONDecoder` bilinmeyen anahtarları sessizce yok sayar.
struct BookmarkFile: Codable {
  struct Entry: Codable {
    let title: String
    let page: Int
    let kids: [Entry]?
  }
  let bookmarks: [Entry]
}

/// `BookmarkOperation`'a özgü hatalar — `OperationError`'a EKLENMEDİ (bkz. `QRError`/
/// `CompressError` aynı desen).
public enum BookmarkError: Error, LocalizedError, Equatable {
  /// "import" kipinde `bookmarkFile` verilmemiş.
  case fileRequired
  /// Verilen JSON okunamadı, ayrıştırılamadı ya da hiç giriş içermiyor.
  case invalidFile
  /// `BookmarkVerification` beklenen sayıyı doğrulayamadı; çıktı silinir.
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .fileRequired: return "Select a bookmark JSON file to import"
    case .invalidFile: return "Bookmark JSON file is invalid or empty"
    case .verificationFailed(let detail):
      return "Bookmark operation could not be verified — \(detail) — output deleted"
    }
  }
}
