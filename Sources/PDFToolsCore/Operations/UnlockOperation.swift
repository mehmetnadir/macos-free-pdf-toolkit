import CoreGraphics
import Foundation

/// Şifre/izin kilidini kaldırır. Çıktı: `<ad>_unlocked.pdf` (kaynağın yanına ya da seçilen klasöre).
public struct UnlockOperation: PDFOperation {
  public static let identifier = "unlock"
  public let id = UnlockOperation.identifier
  public let title = "Kilit Aç"
  public let subtitle = "Şifreyi ve kopyalama/yazdırma kısıtlamalarını kaldırır"
  public let systemImage = "lock.open"
  public let actionTitle = "Kilidi Aç"
  public let outputSuffix = "_unlocked"

  public init() {}

  /// Kilitli/kısıtlı dosya sayısına bakar (`.restricted`/`.passwordRequired`) — zaten kilitsiz
  /// dosyalar için "Kilit Aç" göstermenin anlamı yok (bkz. kullanıcı geri bildirimi, Tur 3).
  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    guard !files.isEmpty else { return .notApplicable(reason: "Önce PDF ekleyin") }
    let lockedCount = files.filter { $0.lockState == .restricted || $0.lockState == .passwordRequired }
      .count
    guard lockedCount > 0 else { return .notApplicable(reason: "Dosyalar zaten şifresiz") }
    return .applicable(fileCount: lockedCount)
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable:
      throw OperationError.unreadable
    case .none:
      return .skipped(reason: "Zaten kilitsiz")
    case .passwordRequired where (context.password ?? "").isEmpty:
      throw OperationError.passwordRequired
    case .restricted, .passwordRequired:
      break
    }

    let engines = context.engines.isEmpty ? EngineLocator.availableEngines() : context.engines
    guard !engines.isEmpty else { throw OperationError.noEngine }

    let output = OutputNaming.uniqueURL(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    // pdfcpu çıktı adında .pdf uzantısı ister; geçici dosya gizli ama .pdf uzantılı.
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default

    var lastError: Error = OperationError.noEngine
    for engine in engines {
      try? fm.removeItem(at: partial)
      do {
        try await engine.decrypt(input: file.url, output: partial, password: context.password, progress: progress)
        // Kanıt: çıktı gerçekten şifresiz mi?
        guard let check = CGPDFDocument(partial as CFURL), !check.isEncrypted, check.numberOfPages > 0 else {
          throw OperationError.outputStillEncrypted(engine: engine.name)
        }
        try fm.moveItem(at: partial, to: output)
        return .produced(urls: [output], note: nil)
      } catch EngineError.wrongPassword {
        try? fm.removeItem(at: partial)
        throw OperationError.wrongPassword
      } catch is CancellationError {
        try? fm.removeItem(at: partial)
        throw CancellationError()
      } catch {
        lastError = error
        continue
      }
    }
    try? fm.removeItem(at: partial)
    throw lastError
  }
}
