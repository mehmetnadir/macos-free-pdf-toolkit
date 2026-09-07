import Foundation

public struct OperationContext: Sendable {
  public var password: String?
  public var outputDirectory: URL?
  /// Boşsa `EngineLocator.availableEngines()` kullanılır.
  public var engines: [any PDFEngine]
  /// İşlem seçenekleri (bkz. `PDFOperation.options`) — anahtar `OperationOption.id`, değer
  /// `choices` içindeki `value`. Bir anahtar yoksa işlem kendi `defaultValue`'sunu kullanmalı.
  public var options: [String: String]

  public init(
    password: String? = nil, outputDirectory: URL? = nil, engines: [any PDFEngine] = [],
    options: [String: String] = [:]
  ) {
    self.password = password
    self.outputDirectory = outputDirectory
    self.engines = engines
    self.options = options
  }
}

public enum OperationOutcome: Sendable, Equatable {
  /// `urls`: üretilen çıktı(lar). Çoğu işlem tek dosya üretir; Parçala/Görüntüye Aktar birden
  /// çok üretir. `note`: kullanıcıya gösterilecek isteğe bağlı ek bilgi; yoksa `nil`.
  case produced(urls: [URL], note: String?)
  case skipped(reason: String)
}

/// Bir işlemin dosyalarla ilişkisi: her dosyayı ayrı ayrı mı işler, yoksa hepsini TEK çağrıda
/// birlikte mi işler (ör. Birleştir). Varsayılan `.perFile` (bkz. protokol uzantısı).
public enum OperationArity: Sendable {
  case perFile
  case combined
}

/// Bir işlemin kullanıcıya sunacağı basit "seçim" ayarı (ör. Parçala kipi, Görüntü biçimi).
/// Bilinçli olarak minimal: yalnız seçim listesi — genel bir form motoru İCAT EDİLMEDİ.
public struct OperationOption: Sendable, Identifiable {
  public let id: String
  /// Kullanıcıya gösterilen etiket, örn. "Kip", "Biçim", "Çözünürlük".
  public let label: String
  public let choices: [(value: String, label: String)]
  public let defaultValue: String

  public init(id: String, label: String, choices: [(value: String, label: String)], defaultValue: String) {
    self.id = id
    self.label = label
    self.choices = choices
    self.defaultValue = defaultValue
  }
}

public enum OperationError: Error, LocalizedError, Equatable {
  case unreadable
  case passwordRequired
  case wrongPassword
  case noEngine
  case outputStillEncrypted(engine: String)
  /// İşlem için gereken motor sistemde bulunamadı (ör. gs, qpdf). Mesaj kullanıcıya doğrudan gösterilir.
  case engineMissing(String)
  /// `TrimVerification` çıktıyı `.failed` olarak işaretledi; çıktı silinir, işlem hata döner.
  case trimVerificationFailed(percent: Double)
  /// `MergeVerification` çıktı sayfa sayısının girdilerin toplamıyla uyuşmadığını tespit etti.
  case mergeVerificationFailed
  /// `SplitVerification` parça sayfa sayılarının toplamının kaynakla uyuşmadığını (ya da 0 sayfalı
  /// bir parça) tespit etti.
  case splitVerificationFailed
  /// Görüntüye aktarma sırasında üretilen dosya sayısı sayfa sayısıyla uyuşmadı ya da bir sayfa
  /// render edilemedi.
  case imageExportVerificationFailed
  /// `run`/`runCombined`'in varsayılan (protokol uzantısı) uygulaması, işlemin `arity`'siyle
  /// UYUŞMAYAN giriş noktasından çağrıldığında fırlatılır — programcı hatası, kullanıcıya normalde
  /// hiç görünmemeli.
  case unsupportedOperationMode(String)

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
    case .mergeVerificationFailed:
      return "Birleştirme doğrulanamadı — sayfa sayısı uyuşmuyor, çıktı silindi"
    case .splitVerificationFailed:
      return "Parçalama doğrulanamadı — sayfa sayıları uyuşmuyor, çıktı silindi"
    case .imageExportVerificationFailed:
      return "Görüntüye aktarma başarısız — üretilen dosya sayısı sayfa sayısıyla uyuşmuyor"
    case .unsupportedOperationMode(let message): return message
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
  /// Dosyaları ayrı ayrı mı yoksa tek çağrıda birlikte mi işler. Varsayılan `.perFile`.
  var arity: OperationArity { get }
  /// Kullanıcıya sunulacak seçimler (ör. kip, biçim, çözünürlük). Varsayılan boş.
  var options: [OperationOption] { get }

  /// `.perFile` işlemler için giriş noktası: her dosya ayrı ayrı çağrılır.
  func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome

  /// `.combined` işlemler için giriş noktası: bekleyen TÜM dosyalar tek çağrıda işlenir.
  func runCombined(
    files: [PDFFileInfo], context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome
}

extension PDFOperation {
  public var arity: OperationArity { .perFile }
  public var options: [OperationOption] { [] }

  /// `.combined` işlemler bu varsayılanı miras alır (kendi `run`'ını yazmaz) — `arity` doğru
  /// ayarlandığı sürece çağıran (`AppModel`, CLI) bu yola hiç girmez.
  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    throw OperationError.unsupportedOperationMode(
      "\(title) yalnızca çoklu dosya (birleşik) modunda çalışır")
  }

  /// `.perFile` işlemler bu varsayılanı miras alır (kendi `runCombined`'ını yazmaz).
  public func runCombined(
    files: [PDFFileInfo], context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    throw OperationError.unsupportedOperationMode(
      "\(title) dosya başına çalışır, birleşik modu yok")
  }
}

public enum OperationRegistry {
  public static let all: [any PDFOperation] = [
    UnlockOperation(), TrimOperation(), MergeOperation(), SplitOperation(), ImageExportOperation(),
  ]

  public static func operation(withID id: String) -> (any PDFOperation)? {
    all.first { $0.id == id }
  }
}
