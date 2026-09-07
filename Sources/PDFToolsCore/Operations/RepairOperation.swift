import CoreGraphics
import Foundation

/// Bozuk/yapısal sorunlu bir PDF'i teşhis edip onarır. Motor: yalnız qpdf. Özel bir "--repair"
/// bayrağı YOK — teşhis `qpdf --check` ile, onarım ise qpdf'in KENDİSİ `giriş çıkış` biçiminde SADE
/// bir yeniden yazma sırasında xref tablosunu (ve diğer kurtarılabilir yapısal sorunları) yeniden
/// kurmasıyla yapılır. Gerçek bir bozuk-xref'li dosyayla ölçülüp doğrulandı: bu sade yeniden yazma
/// sonrası `qpdf --check` sıfır uyarıya dönüyor (bkz. `RepairVerification`). Çıktı: `<ad>_onarilmis.pdf`.
public struct RepairOperation: PDFOperation {
  public static let identifier = "repair"
  public let id = RepairOperation.identifier
  public let title = "Onar"
  public let subtitle = "Yapısal sorunları teşhis edip yeniden yazarak onarır"
  public let systemImage = "bandage"
  public let actionTitle = "Onar"
  public let outputSuffix = "_onarilmis"

  public init() {}

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable: throw OperationError.unreadable
    case .passwordRequired: throw OperationError.passwordRequired
    case .restricted, .none: break
    }
    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf motoru bulunamadı")
    }

    progress(0)
    let before = try await RepairVerification.diagnose(qpdf: qpdf, url: file.url)
    guard before.hasIssues else {
      return .skipped(reason: "Dosyada sorun bulunamadı")
    }
    progress(0.2)

    let output = OutputNaming.uniqueURL(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    do {
      // Bilerek `--replace-input` DEĞİL: kaynağa dokunulmaz, güvenli/geri dönülebilir bir yeniden
      // yazma yapılır (bkz. dosya üstü yorum).
      let result = try await ProcessRunner.run(qpdf, arguments: [file.url.path, partial.path])
      guard result.status == 0 || result.status == 3 else {
        throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
      }
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }
    progress(0.7)

    guard let doc = CGPDFDocument(partial as CFURL), doc.numberOfPages == file.pageCount else {
      try? fm.removeItem(at: partial)
      throw RepairError.verificationFailed("sayfa sayısı korunmadı")
    }

    // Kanıt: onarım GERÇEKTEN uyarı/hata sayısını azaltmış mı — motorun sessizce başarılı dönmesine
    // güvenilmiyor.
    let after = try await RepairVerification.diagnose(qpdf: qpdf, url: partial)
    guard RepairVerification.improved(before: before, after: after) else {
      try? fm.removeItem(at: partial)
      throw RepairError.verificationFailed(
        "uyarı/hata sayısı azalmadı (\(before.issueLineCount) → \(after.issueLineCount))")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    let note = "\(before.issueLineCount) uyarı/hata bulundu, onarım sonrası \(after.issueLineCount) kaldı"
    return .produced(urls: [output], note: note)
  }
}

public enum RepairError: Error, LocalizedError, Equatable {
  /// `RepairVerification` çıktının iyileştiğini doğrulayamadı; çıktı silinir, işlem hata döner.
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .verificationFailed(let detail):
      return "Onarım doğrulanamadı — \(detail) — çıktı silindi"
    }
  }
}
