import Foundation

public enum EngineError: Error, LocalizedError, Equatable {
  case wrongPassword
  case failed(status: Int32, message: String)

  public var errorDescription: String? {
    switch self {
    case .wrongPassword: return "Şifre yanlış"
    case .failed(let status, let message):
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Motor hata verdi (kod \(status))" : trimmed
    }
  }
}

/// PDF şifre çözme motoru. Her motor bir komut satırı aracını sarar.
public protocol PDFEngine: Sendable {
  var name: String { get }
  var executable: URL { get }
  /// `input`'u çözüp `output`'a yazar. `progress` 0...1 arası; motor destekliyorsa çağrılır.
  func decrypt(
    input: URL, output: URL, password: String?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws
}

extension PDFEngine {
  static func percent(in line: String) -> Double? {
    guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
    let digits = line[range].dropLast()
    guard let value = Double(digits) else { return nil }
    return min(max(value / 100, 0), 1)
  }
}

public struct QPDFEngine: PDFEngine {
  public let name = "qpdf"
  public let executable: URL
  public init(executable: URL) { self.executable = executable }

  public func decrypt(
    input: URL, output: URL, password: String?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    var arguments = ["--decrypt", "--progress"]
    if let password, !password.isEmpty { arguments.append("--password=\(password)") }
    arguments += [input.path, output.path]
    let result = try await ProcessRunner.run(executable, arguments: arguments) { line in
      if let value = Self.percent(in: line) { progress(value) }
    }
    // qpdf: 0 = tamam, 3 = uyarılarla tamam (çıktı yazıldı), 2 = hata
    switch result.status {
    case 0, 3: return
    default:
      if result.stderr.lowercased().contains("password") { throw EngineError.wrongPassword }
      throw EngineError.failed(status: result.status, message: result.stderr)
    }
  }
}

public struct PDFCPUEngine: PDFEngine {
  public let name = "pdfcpu"
  public let executable: URL
  public init(executable: URL) { self.executable = executable }

  public func decrypt(
    input: URL, output: URL, password: String?,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    var arguments = ["decrypt"]
    if let password, !password.isEmpty { arguments += ["--upw", password, "--opw", password] }
    arguments += [input.path, output.path]
    let result = try await ProcessRunner.run(executable, arguments: arguments)
    guard result.status == 0 else {
      let combined = (result.stderr + result.stdout).lowercased()
      if combined.contains("password") { throw EngineError.wrongPassword }
      throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
    }
  }
}
