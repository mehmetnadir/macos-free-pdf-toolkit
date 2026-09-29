import Foundation

/// qpdf'e giden dosya yolu argümanlarını "-" ile başlayan bir ad BAYRAK sanılmasına karşı korur.
///
/// GÜVENLİK ÖLÇÜMÜ (2026-09-29): qpdf'in KENDİ "--" sonlandırıcısı yalnızca `--pages .. --` /
/// `--encrypt .. --` gibi İÇ İÇE kollarda geçerli bir sözdizimi parçasıdır — tekil komutlar için
/// GENEL bir "seçenek sonu" işareti DEĞİLDİR. Gerçek ikili ile ölçüldü: adı `-` ile başlayan bir
/// dosya (`-bare.pdf`) verildiğinde `qpdf --decrypt --progress -- -bare.pdf out.pdf`,
/// `qpdf --check -- -bare.pdf`, `qpdf --linearize -- -bare.pdf out.pdf` ve
/// `qpdf --object-streams=generate .. -- -bare.pdf out.pdf`'in HEPSİ hâlâ
/// "qpdf: unrecognized argument -bare.pdf" ile başarısız oluyor — yani `--` eklemek burada YANILTICI
/// bir sahte güvenlik olurdu (bilerek EKLENMEDİ). Ölçülüp DOĞRULANAN tek çözüm: yolun `./` ile
/// başlamasını sağlamak (qpdf'in kendi tarayıcısı böylece ilk karakter olarak `-` GÖRMÜYOR).
/// Pratikte bu kod yolundaki her `URL.path` zaten MUTLAK (`/` ile başlar, bkz.
/// `URL(fileURLWithPath:)` ve SwiftUI `.dropDestination(for: URL.self)` — ikisi de göreli bir yolu
/// asla üretmez), yani bugün hiçbir çağıran bu dalı tetiklemiyor; yine de motor katmanının KENDİSİ
/// çağıranın disiplinine güvenmemeli — ileride biri yanlışlıkla göreli bir `URL` üretirse bu TEK
/// nokta koruma devreye girer.
enum QPDFArgument {
  static func path(for url: URL) -> String {
    let path = url.path
    return path.hasPrefix("-") ? "./" + path : path
  }
}

/// pdfcpu HER komuttan önce kullanıcının KÜRESEL config dosyasını (`~/Library/Application
/// Support/pdfcpu/config.yml`) okuyup doğrular — ve o dosyayı BİZİM UYGULAMAMIZ (pakette gömülü
/// pdfcpu ikilisi) oluşturmuştu. Güvenlik danışmanlıkları yüzünden geçilmesi gereken pdfcpu
/// v0.16.0, eski şemalı config'i görünce HER komutu reddediyor: "configuration reset required /
/// detected schema version: legacy" (ölçüldü 2026-09-29). Ölçülüp DOĞRULANAN çözüm: `--conf disable`
/// — pdfcpu'yu kullanıcı config'ini hiç okumadan/yazmadan sabit varsayılanlarla çalıştırır. Hem
/// YENİ (v0.16.0) hem pakette gömülü ESKİ (v0.15.0) ikilide aynı çıkış kodu/çıktıyla çalıştığı
/// ayrıca doğrulandı — geriye uyumlu, mevcut davranış BOZULMUYOR. Yan kazanç: uygulama artık
/// kullanıcının Library'sine yazmıyor, Homebrew'la kurulu bir pdfcpu ile durum paylaşmıyor.
enum PDFCPUArgument {
  static let disableConfig = ["--conf", "disable"]
}

public enum EngineError: Error, LocalizedError, Equatable {
  case wrongPassword
  case failed(status: Int32, message: String)

  public var errorDescription: String? {
    switch self {
    case .wrongPassword: return "Wrong password"
    case .failed(let status, let message):
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Engine failed (code \(status))" : trimmed
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
    arguments += [QPDFArgument.path(for: input), QPDFArgument.path(for: output)]
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
    // pdfcpu'nun ilerleme bayrağı YOK — ara değer UYDURULMAZ (sahte ilerleme yanıltır).
    // Yalnızca başladı/bitti uç noktaları bildirilir.
    progress(0)
    var arguments = ["decrypt"] + PDFCPUArgument.disableConfig
    if let password, !password.isEmpty { arguments += ["--upw", password, "--opw", password] }
    // "--": pdfcpu'nun Cobra tabanlı ayrıştırıcısı bunu GENEL bir "seçenek sonu" işareti olarak
    // destekliyor (ölçüldü, 2026-09-29: `-` ile başlayan bir dosya adı `--` OLMADAN
    // "unknown shorthand flag" ile reddediliyor, `--` İLE doğru şekilde dosya yolu sayılıyor) —
    // qpdf'in aksine (bkz. `QPDFArgument` yorumu) burada `--` GERÇEKTEN işe yarıyor.
    arguments += ["--", input.path, output.path]
    let result = try await ProcessRunner.run(executable, arguments: arguments)
    guard result.status == 0 else {
      let combined = (result.stderr + result.stdout).lowercased()
      if combined.contains("password") { throw EngineError.wrongPassword }
      throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
    }
    progress(1)
  }
}
