import Foundation
import PDFKit

/// Bir PDF'in metin katmanını düz metin dosyasına aktarır. Motor YOK — alt süreç çalıştırılmaz;
/// yalnızca sistem çerçevesi PDFKit (`PDFDocument` / `PDFPage.string`) kullanılır. Taranmış (yalnızca
/// görsel, metin katmanı olmayan) sayfalarda `page.string` `nil` döner — gerçek bir örnekle ölçülüp
/// doğrulandı: metin çizilen bir sayfada dolu dize, yalnız görsel/şekil içeren bir sayfada `nil`.
/// Çıktı: `<ad>.txt`. Diğer işlemlerin aksine bir sonek YOK — bu yüzden `OutputNaming.uniqueURL`
/// (her zaman GİRDİNİN uzantısını korur) yerine bu dosyaya özel küçük bir adlandırma yardımcısı
/// kullanılır.
public struct ExtractTextOperation: PDFOperation {
  public static let identifier = "extracttext"
  public let id = ExtractTextOperation.identifier
  public let title = "Extract Text"
  public let subtitle = "Exports the text layer to a plain text file"
  public let systemImage = "doc.plaintext"
  public let actionTitle = "Extract Text"

  public static let layoutOptionID = "layout"

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.layoutOptionID, label: "Layout",
        choices: [("plain", "Plain"), ("pages", "Page breaks")], defaultValue: "plain"),
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
    guard let document = PDFDocument(url: file.url) else {
      throw OperationError.unreadable
    }
    let total = document.pageCount
    guard total > 0 else { return .skipped(reason: "No pages") }

    var pageTexts: [String] = []
    pageTexts.reserveCapacity(total)
    for i in 0..<total {
      try Task.checkCancellation()
      pageTexts.append(document.page(at: i)?.string ?? "")
      progress(Double(i + 1) / Double(total) * 0.8)
    }

    let hasContent = pageTexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard hasContent else {
      return .skipped(reason: "No text layer — this may be a scanned PDF; try OCR")
    }

    let layout = context.options[Self.layoutOptionID] ?? "plain"
    let combined = Self.combine(pageTexts, layout: layout)

    let output = Self.uniqueTextURL(for: file.url, in: context.outputDirectory)
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
    progress(0.9)

    // Kanıt: çıktı dosyası GERÇEKTEN boş değil (yazma sırasında sessiz bir kesilme olmadığından emin
    // olmak için diskten geri okunuyor, bellekteki `combined`'a güvenilmiyor).
    guard
      let written = try? String(contentsOf: partial, encoding: .utf8),
      !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      try? fm.removeItem(at: partial)
      throw ExtractTextError.verificationFailed("output file is empty")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: nil)
  }

  /// "pages" kipinde sayfalar arasına `--- page N ---` ayracı koyar (N: takip eden sayfanın
  /// numarası); "plain" kipinde sayfalar yalnız boş satırla ayrılır.
  static func combine(_ pageTexts: [String], layout: String) -> String {
    guard !pageTexts.isEmpty else { return "" }
    guard layout == "pages" else { return pageTexts.joined(separator: "\n\n") }
    var result = pageTexts[0]
    for index in 1..<pageTexts.count {
      result += "\n\n--- page \(index + 1) ---\n\n" + pageTexts[index]
    }
    return result
  }

  private static func uniqueTextURL(for input: URL, in directory: URL?) -> URL {
    let dir = directory ?? input.deletingLastPathComponent()
    let stem = input.deletingPathExtension().lastPathComponent
    var candidate = dir.appendingPathComponent(stem).appendingPathExtension("txt")
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent("\(stem) \(counter)").appendingPathExtension("txt")
      counter += 1
    }
    return candidate
  }
}

public enum ExtractTextError: Error, LocalizedError, Equatable {
  /// Yazılan metin dosyası boş çıktı; çıktı silinir, işlem hata döner.
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .verificationFailed(let detail):
      return "Text extraction could not be verified — \(detail) — output deleted"
    }
  }
}
