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

/// Bir işlemin verilen dosya listesine uygulanıp uygulanamayacağı (bkz. eylem kartları,
/// `.claude/CLAUDE.md`). Arayüz bunu hem kartın soluk/etkin durumunu hem de "Çalıştır" düğmesinin
/// etkinliğini belirlemek için kullanır.
public enum OperationApplicability: Sendable, Equatable {
  /// `fileCount`: bu işlemin GERÇEKTEN etkileyeceği dosya sayısı (ör. Kilit Aç'ta kilitli dosya
  /// sayısı, listedeki TÜM dosya sayısı değil).
  case applicable(fileCount: Int)
  /// `reason`: İngilizce, tek cümle, kullanıcıya doğrudan gösterilir (kart alt metni + `.help()`).
  case notApplicable(reason: String)
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
  /// Çıktının sayfa ÖLÇÜSÜ kaynağın TrimBox'ıyla uyuşmuyor ya da çıktı hâlâ kesim payı bildiriyor.
  case trimGeometryFailed(page: Int?)
  /// Kesim çıktısının içeriği kaynaktan farklı render ediliyor (renk uzayı dönüşümü, saydamlık
  /// düzleştirme, boş sayfa). Kayıpsız kipte beklenen fark 0,00 — bu hata gerçek bir hasar demek.
  case trimFidelityFailed(percent: Double)
  /// Kayıpsız kesim çıktısının İÇERİK ENVANTERİ kaynaktan farklı (görüntü/renk uzayı/font/XMP
  /// sayısı ya da PDF sürümü değişmiş) — kayıpsız kipte bu olamaz, olduysa dosya yeniden yazılmış.
  case trimContentChanged(String)
  /// Çıktının İSKELETİ bozuk (bkz. `PDFStructureCheck`): dosya bazı okuyucularda açılıp
  /// bazılarında açılmayacak durumda — teslim edilmez.
  case outputStructureBroken(String)
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
    case .unreadable: return "File is not a valid PDF"
    case .passwordRequired: return "This file requires a password"
    case .wrongPassword: return "Wrong password"
    case .noEngine: return "No PDF engine found (qpdf / pdfcpu)"
    case .outputStillEncrypted(let engine): return "\(engine) output is still encrypted"
    case .engineMissing(let message): return message
    case .trimVerificationFailed(let percent):
      let formatted = String(format: "%.1f", percent)
      return "Bleed margin could not be fully removed (residual \(formatted)%) — output deleted"
    case .trimGeometryFailed(let page):
      let where_ = page.map { " (page \($0))" } ?? ""
      return "Trimmed page size doesn't match the trim line\(where_) — output deleted"
    case .trimFidelityFailed(let percent):
      let formatted = String(format: "%.2f", percent)
      return "Trimmed pages don't match the original content (\(formatted)% of pixels differ) "
        + "— output deleted"
    case .trimContentChanged(let detail):
      return "Trim changed the file's content (\(detail)) — output deleted"
    case .outputStructureBroken(let detail):
      return "Output PDF structure is broken (\(detail)) — output deleted"
    case .mergeVerificationFailed:
      return "Merge could not be verified — page count mismatch, output deleted"
    case .splitVerificationFailed:
      return "Split could not be verified — page counts mismatch, output deleted"
    case .imageExportVerificationFailed:
      return "Image export failed — number of files produced doesn't match the page count"
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
  /// Bu işlemin çıktı adına ekleyebileceği EKLER (ör. `["_compressed"]`). Zincirleme
  /// adlandırma (`OutputNaming.knownSuffixes`) bunların hepsini tanımak ZORUNDA — tanımazsa
  /// o işlemin eki soyulmaz ve adlar `..._a_b_c.pdf` diye uzamaya geri döner. Sözleşme
  /// `Tur11Tests.testEveryOperationSuffixIsKnownToTheNamer` ile çivilenmiştir.
  /// Boş dizi = ada ek eklemez (ör. Metin Çıkar doğrudan `.txt` yazar).
  var outputSuffixes: [String] { get }

  /// Bu işlem verilen dosya listesine uygulanabilir mi (bkz. `OperationApplicability`). Varsayılan
  /// (protokol uzantısı): dosya varsa `.applicable(files.count)`, yoksa "Add a PDF first". Her
  /// işlem kendi kuralına göre EZER (ör. Kilit Aç yalnız kilitli dosyaları sayar).
  func applicability(for files: [PDFFileInfo]) -> OperationApplicability

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
  public var outputSuffixes: [String] { [] }

  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    files.isEmpty ? .notApplicable(reason: "Add a PDF first") : .applicable(fileCount: files.count)
  }

  /// `.combined` işlemler bu varsayılanı miras alır (kendi `run`'ını yazmaz) — `arity` doğru
  /// ayarlandığı sürece çağıran (`AppModel`, CLI) bu yola hiç girmez.
  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    throw OperationError.unsupportedOperationMode(
      "\(title) only works in combined (multi-file) mode")
  }

  /// `.perFile` işlemler bu varsayılanı miras alır (kendi `runCombined`'ını yazmaz).
  public func runCombined(
    files: [PDFFileInfo], context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    throw OperationError.unsupportedOperationMode(
      "\(title) runs per file, it has no combined mode")
  }
}

public enum OperationRegistry {
  public static let all: [any PDFOperation] = [
    UnlockOperation(), TrimOperation(), MergeOperation(), SplitOperation(), ImageExportOperation(),
    PageEditOperation(), CompressOperation(), EncryptOperation(),
    LinearizeOperation(), RepairOperation(), ExtractImagesOperation(), ExtractTextOperation(),
    QRAddOperation(), QRExtractOperation(), OCROperation(), SearchablePDFOperation(),
    WatermarkRemoveOperation(), WatermarkAddOperation(), PageNumberOperation(),
    BookmarkOperation(),
  ]

  public static func operation(withID id: String) -> (any PDFOperation)? {
    all.first { $0.id == id }
  }

  /// Dosya listesine göre öne çıkan (varsayılan seçili) işlem. Saf/yan etkisiz — motor kurulu mu
  /// gibi ortam kontrolü YAPMAZ (bkz. testler); yalnız dosya metaverisine bakar. Sıra: kilitli
  /// dosya var mı → Kilit Aç, kesim payı var mı → Kesim Payını At, 2+ dosya mı → Birleştir,
  /// aksi halde → Sayfa Düzenle. Liste boşsa `nil` (arayüz mevcut seçimi korur).
  public static func suggested(for files: [PDFFileInfo]) -> (any PDFOperation)? {
    guard !files.isEmpty else { return nil }
    if files.contains(where: { $0.lockState == .restricted || $0.lockState == .passwordRequired }) {
      return operation(withID: UnlockOperation.identifier)
    }
    if files.contains(where: \.hasBleed) {
      return operation(withID: TrimOperation.identifier)
    }
    if files.count >= 2 {
      return operation(withID: MergeOperation.identifier)
    }
    return operation(withID: PageEditOperation.identifier)
  }
}
