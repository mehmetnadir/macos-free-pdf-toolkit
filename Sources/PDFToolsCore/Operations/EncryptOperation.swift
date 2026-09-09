import CoreGraphics
import Foundation

/// `EncryptOperation`'ın kendi hata türü. Yeni bir `OperationError` case'i EKLEMEK yerine (bu tur
/// `Operations/PDFOperation.swift`'e DOKUNMUYOR, bkz. `CompressError`'daki aynı gerekçe) kendi
/// türü tanımlandı.
public enum EncryptError: Error, LocalizedError, Equatable {
  case noPasswordProvided
  case verificationFailed

  public var errorDescription: String? {
    switch self {
    case .noPasswordProvided: return "Enter at least one password"
    case .verificationFailed: return "Encryption could not be verified — output deleted"
    }
  }
}

/// Şifreleme uygular (256-bit AES SABİT — 40/128-bit güvensiz sayıldığından seçenek olarak
/// SUNULMUYOR). Motor: yalnız qpdf `--encrypt --user-password=<u> --owner-password=<o> --bits=256
/// [izin bayrakları] -- in out` (sözdizimi `qpdf --help=encryption` ile doğrulandı, bkz. dosya
/// sonu yorumu). Çıktı: `<ad>_encrypted.pdf`.
public struct EncryptOperation: PDFOperation {
  public static let identifier = "encrypt"
  public let id = EncryptOperation.identifier
  public let title = "Encrypt"
  public let subtitle = "Password-protects the file with 256-bit AES"
  public let systemImage = "lock"
  public let actionTitle = "Encrypt"
  public let outputSuffix = "_encrypted"
  public var outputSuffixes: [String] { [outputSuffix] }

  /// `OperationContext.options` anahtarları — `OperationOption.choices`'tan GELMEZ (serbest metin
  /// parola alanı `OperationOption`'ın "seçim" modeliyle ifade edilemez), arayüz doğrudan bu
  /// anahtarlara yazar.
  public static let userPasswordOptionID = "userPassword"
  public static let ownerPasswordOptionID = "ownerPassword"
  public static let permissionsOptionID = "permissions"

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.permissionsOptionID, label: "Permissions",
        choices: [
          ("all", "Everything allowed"),
          ("noprint", "Printing disabled"),
          ("nocopy", "Copying disabled"),
          ("readonly", "Printing + copying disabled"),
        ], defaultValue: "all"),
    ]
  }

  /// Zaten şifreli dosyaları saymaz (`run()`'da `.skipped(reason: "Already encrypted")` ile atlanır) —
  /// buradaki basit tutuluş bilinçli: görev tarifinde "dosya varsa `.applicable(files.count)`"
  /// istendi, kartın alt metnini özelleştirmek `ContentView.cardSubtitle`'ın işi (bu turun kapsamı
  /// dışında).
  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    files.isEmpty ? .notApplicable(reason: "Add a PDF first") : .applicable(fileCount: files.count)
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable: throw OperationError.unreadable
    case .restricted, .passwordRequired: return .skipped(reason: "Already encrypted")
    case .none: break
    }

    let userPassword = context.options[Self.userPasswordOptionID] ?? ""
    let ownerPassword = context.options[Self.ownerPasswordOptionID] ?? ""
    guard !userPassword.isEmpty || !ownerPassword.isEmpty else {
      throw EncryptError.noPasswordProvided
    }

    // Güvensiz kombinasyonlar: ÇALIŞ ama uyar (çıktı reddedilmez, yalnız `note`'ta bildirilir).
    var notes: [String] = []
    var needsAllowInsecure = false
    if !userPassword.isEmpty, ownerPassword.isEmpty {
      // qpdf 256-bit'te bunu kendisi de reddediyor (`--allow-insecure` verilmezse hata) — bu
      // yüzden bayrağı biz ekliyoruz, kullanıcıyı hatayla değil notla bilgilendiriyoruz.
      notes.append("owner password is empty — output can still be opened without a password")
      needsAllowInsecure = true
    } else if !userPassword.isEmpty, userPassword == ownerPassword {
      notes.append("user and owner password are the same — separate passwords are more secure")
    }

    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf engine not found")
    }

    let permissions = context.options[Self.permissionsOptionID] ?? "all"
    let output = OutputNaming.uniqueURL(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    var arguments = ["--encrypt"]
    if !userPassword.isEmpty { arguments.append("--user-password=\(userPassword)") }
    if !ownerPassword.isEmpty { arguments.append("--owner-password=\(ownerPassword)") }
    arguments.append("--bits=256")
    switch permissions {
    case "noprint": arguments.append("--print=none")
    case "nocopy": arguments.append("--extract=n")
    case "readonly": arguments += ["--print=none", "--extract=n"]
    default: break  // "all": kısıtlama bayrağı yok, hepsi serbest kalır.
    }
    if needsAllowInsecure { arguments.append("--allow-insecure") }
    arguments.append("--")
    arguments += [file.url.path, partial.path]

    progress(0)
    do {
      let result = try await ProcessRunner.run(qpdf, arguments: arguments)
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
    progress(0.9)

    // Kanıt: çıktı GERÇEKTEN şifreli mi + doğru parola açıyor mu + YANLIŞ parola açmıyor mu?
    // (bkz. `EncryptVerification` yorumu — qpdf'in çıkış kodu 0 dönmesi tek başına kanıt değil.)
    guard EncryptVerification.verify(partial, userPassword: userPassword) else {
      try? fm.removeItem(at: partial)
      throw EncryptError.verificationFailed
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: notes.isEmpty ? nil : notes.joined(separator: " · "))
  }
}

// Sözdizimi doğrulaması (2026-09-08, `./vendor/bin/qpdf --help=encryption` ve gerçek komut
// çalıştırmalarıyla): 256-bit için `--print=[none|low|full]` ve `--extract=[y|n]` geçerli
// bayraklar; boş sahip parolasıyla non-empty kullanıcı parolası qpdf'i "insecure" hatasına
// düşürüyor, `--allow-insecure` (yalnız 256-bit'e özel, `--encrypt ... --` bloğunun İÇİNDE)
// bunu aşıyor — ölçüldü: bayraksız status=2 + "insecure" mesajı, bayrakla status=0.
