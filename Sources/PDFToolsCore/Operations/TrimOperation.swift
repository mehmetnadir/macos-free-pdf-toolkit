import Foundation

/// Kesim payını (baskı taşma payı / bleed, TrimBox dışı içerik) kalıcı olarak atar.
/// Motor: Ghostscript (`gs`), yalnızca kullanıcının sisteminde kurulu bulunursa — bkz.
/// `GhostscriptEngine.swift` (neden pakete gömülmediği için lisans notu).
/// Çıktı: `<ad>_kesilmis.pdf` (kaynağın yanına ya da seçilen klasöre).
public struct TrimOperation: PDFOperation {
  public static let identifier = "trim"
  public let id = TrimOperation.identifier
  public let title = "Kesim Payını At"
  public let subtitle = "Baskı taşma payını ve kesim dışı içeriği kalıcı olarak siler"
  public let systemImage = "crop"
  public let actionTitle = "Kesim Payını At"
  public let outputSuffix = "_kesilmis"

  public init() {}

  /// Kesim payı OLAN dosya sayısına bakar; motor kontrolü BUNUN İÇİNE taşındı (bkz.
  /// `.claude/CLAUDE.md`) — `run()` içindeki `EngineLocator.trimEngine()` kontrolü savunma katmanı
  /// olarak KALIYOR (arayüz bu fonksiyonu atlayıp doğrudan `run()`'ı çağırırsa yine korunmalı).
  /// Sıra bilerek BÖYLE: kesim payı hiç yoksa motor kurulu olmasa bile "Kesim payı yok" demek daha
  /// doğru (kurulum gerektirmeyen bir durum için Ghostscript istemek yanıltıcı olurdu).
  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    guard !files.isEmpty else { return .notApplicable(reason: "Önce PDF ekleyin") }
    let bleedCount = files.filter(\.hasBleed).count
    guard bleedCount > 0 else { return .notApplicable(reason: "Kesim payı yok") }
    guard EngineLocator.trimEngine() != nil else {
      return .notApplicable(reason: "Ghostscript gerekli — brew install ghostscript")
    }
    return .applicable(fileCount: bleedCount)
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable:
      throw OperationError.unreadable
    case .passwordRequired:
      // Şifre çözme bu işlemin kapsamında değil (Kilit Aç'ın işi); kullanıcı önce onu çalıştırmalı.
      throw OperationError.passwordRequired
    case .restricted, .none:
      break
    }

    guard file.trimBox != nil else {
      return .skipped(reason: "Kesim payı yok")
    }

    guard let engine = EngineLocator.trimEngine() else {
      throw OperationError.engineMissing("Ghostscript gerekli: brew install ghostscript")
    }

    let output = OutputNaming.uniqueURL(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    // gs de çıktı adında uzantı bekler; diğer işlemlerle tutarlı gizli-ama-.pdf-uzantılı ad.
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    do {
      try await engine.trim(input: file.url, output: partial, progress: progress)
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    // Kanıt: gs kutu üstverisini değiştirip içeriği kırpmadan bırakabilir (bkz. GhostscriptEngine
    // yorumu) — kutuya değil, gerçekten render edilen piksele güven.
    let verification = TrimVerification.verify(partial)
    guard verification.verdict != .failed else {
      try? fm.removeItem(at: partial)
      throw OperationError.trimVerificationFailed(percent: verification.residuePercent)
    }

    try fm.moveItem(at: partial, to: output)

    var notes: [String] = []
    if verification.verdict == .partial {
      let formatted = String(format: "%.1f", verification.residuePercent)
      notes.append("kalıntı %\(formatted)")
    }
    if !PDFFileInfo.trimBoxIsConsistent(output) {
      notes.append("sayfalar arası kesim payı tutarsız")
    }
    return .produced(urls: [output], note: notes.isEmpty ? nil : notes.joined(separator: " · "))
  }
}
