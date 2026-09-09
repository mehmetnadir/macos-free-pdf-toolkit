import CoreGraphics
import Foundation

/// Bozuk/yapısal sorunlu bir PDF'i teşhis edip onarır. Motor: yalnız qpdf. Özel bir "--repair"
/// bayrağı YOK — teşhis `qpdf --check` ile, onarım ise qpdf'in KENDİSİ `giriş çıkış` biçiminde SADE
/// bir yeniden yazma sırasında xref tablosunu (ve diğer kurtarılabilir yapısal sorunları) yeniden
/// kurmasıyla yapılır. Gerçek bir bozuk-xref'li dosyayla ölçülüp doğrulandı: bu sade yeniden yazma
/// sonrası `qpdf --check` sıfır uyarıya dönüyor (bkz. `RepairVerification`).
/// Çıktı: `<ad>_repaired.pdf`.
public struct RepairOperation: PDFOperation {
  public static let identifier = "repair"
  public let id = RepairOperation.identifier
  public let title = "Repair"
  public let subtitle = "Diagnoses structural issues and fixes them by rewriting the file"
  public let systemImage = "bandage"
  public let actionTitle = "Repair"
  public let outputSuffix = "_repaired"
  public var outputSuffixes: [String] { [outputSuffix] }

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
      throw OperationError.engineMissing("qpdf engine not found")
    }

    progress(0)
    let before = try await RepairVerification.diagnose(qpdf: qpdf, url: file.url)
    guard before.hasIssues else {
      return .skipped(reason: "No issues found in the file")
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
      throw RepairError.verificationFailed("page count wasn't preserved")
    }

    // Kanıt: onarım GERÇEKTEN uyarı/hata sayısını azaltmış mı — motorun sessizce başarılı dönmesine
    // güvenilmiyor.
    let after = try await RepairVerification.diagnose(qpdf: qpdf, url: partial)
    guard RepairVerification.improved(before: before, after: after) else {
      try? fm.removeItem(at: partial)
      throw RepairError.verificationFailed(
        "warning/error count didn't decrease (\(before.issueLineCount) → \(after.issueLineCount))")
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    // Ham uyarı/hata SAYISI kullanıcıya bir şey ifade etmez (bkz. görev tanımı) — asıl karar
    // noktası hepsi mi düzeldi yoksa bir kısmı mı kaldı.
    let note =
      after.issueLineCount == 0
      ? "File structure repaired"
      : "File structure repaired — some issues could not be fixed automatically"
    return .produced(urls: [output], note: note)
  }
}

public enum RepairError: Error, LocalizedError, Equatable {
  /// `RepairVerification` çıktının iyileştiğini doğrulayamadı; çıktı silinir, işlem hata döner.
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .verificationFailed(let detail):
      return "Repair could not be verified — \(detail) — output deleted"
    }
  }
}
