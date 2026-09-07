import Foundation

public struct OperationContext: Sendable {
  public var password: String?
  public var outputDirectory: URL?
  /// Boşsa `EngineLocator.availableEngines()` kullanılır.
  public var engines: [any PDFEngine]

  public init(password: String? = nil, outputDirectory: URL? = nil, engines: [any PDFEngine] = []) {
    self.password = password
    self.outputDirectory = outputDirectory
    self.engines = engines
  }
}

public enum OperationOutcome: Sendable, Equatable {
  /// `note`: kullanıcıya gösterilecek isteğe bağlı ek bilgi (ör. kesim payında kalan iz oranı).
  /// Bilgi yoksa `nil`.
  case produced(URL, note: String?)
  case skipped(reason: String)
}

public enum OperationError: Error, LocalizedError, Equatable {
  case unreadable
  case passwordRequired
  case wrongPassword
  case noEngine
  case outputStillEncrypted(engine: String)
  /// İşlem için gereken motor sistemde bulunamadı (ör. gs). Mesaj kullanıcıya doğrudan gösterilir.
  case engineMissing(String)
  /// `TrimVerification` çıktıyı `.failed` olarak işaretledi; çıktı silinir, işlem hata döner.
  case trimVerificationFailed(percent: Double)

  public var errorDescription: String? {
    switch self {
    case .unreadable: return "Dosya geçerli bir PDF değil"
    case .passwordRequired: return "Bu dosya için şifre gerekli"
    case .wrongPassword: return "Şifre yanlış"
    case .noEngine: return "PDF motoru bulunamadı (qpdf / pdfcpu)"
    case .outputStillEncrypted(let engine): return "\(engine) çıktısı hâlâ şifreli"
    case .engineMissing(let message): return message
    case .trimVerificationFailed(let percent):
      let formatted = String(format: "%.1f", percent)
      return "Kesim payı yeterince temizlenemedi (kalıntı %\(formatted)) — çıktı silindi"
    }
  }
}

/// Araç kutusundaki bir işlem. Yeni işlemler bu protokole uyar ve `OperationRegistry`'ye eklenir.
public protocol PDFOperation: Sendable {
  var id: String { get }
  var title: String { get }
  var subtitle: String { get }
  var systemImage: String { get }
  /// Çalıştır düğmesinin etiketi, örn. "Kilidi Aç".
  var actionTitle: String { get }

  func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome
}

public enum OperationRegistry {
  public static let all: [any PDFOperation] = [UnlockOperation(), TrimOperation()]

  public static func operation(withID id: String) -> (any PDFOperation)? {
    all.first { $0.id == id }
  }
}
