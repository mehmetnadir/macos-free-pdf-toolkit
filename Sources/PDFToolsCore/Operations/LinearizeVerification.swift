import Foundation

/// "Hızlı Görünüm İçin Hazırla" (linearize) çıktısının GERÇEKTEN lineerleştirilip
/// lineerleştirilmediğini ölçer. qpdf'in sessizce başarılı dönmesine güvenmez — `qpdf --check`
/// çıktısını KENDİSİ okur. Çıktı biçimi gerçek komut çalıştırılıp doğrulandı (bkz. dosya üstü
/// yorum, `LinearizeOperation`): `qpdf --check` STDOUT'a ya "File is linearized" ya da
/// "File is not linearized" satırı yazar; ikisi de "linearized" alt dizgesini içerdiği için yalnız
/// `contains("linearized")` YETERSİZ — tam ifade "File is linearized" aranır (bu, "File is not
/// linearized" içinde art arda GEÇMEZ, çünkü aralarına "not " girer).
public enum LinearizeVerification {
  public struct Diagnosis: Sendable, Equatable {
    public let exitStatus: Int32
    public let isLinearized: Bool
    public let rawOutput: String
  }

  /// `qpdf --check <url>` çalıştırır ve çıktıyı yorumlar. `qpdf`'in kendi çıkış kodu sözleşmesi
  /// (0=temiz, 3=uyarılı ama başarılı, 2=hata) diğer tüm qpdf çağrılarıyla aynı şekilde ele alınır.
  public static func diagnose(qpdf: URL, url: URL) async throws -> Diagnosis {
    let result = try await ProcessRunner.run(qpdf, arguments: ["--check", url.path])
    let combined = result.stdout + result.stderr
    return Diagnosis(
      exitStatus: result.status, isLinearized: combined.contains("File is linearized"),
      rawOutput: combined)
  }
}
