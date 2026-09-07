import Foundation

/// "Onar" işleminin teşhis ve doğrulama ölçümü: `qpdf --check` çalıştırıp çıkış kodunu VE stderr'e
/// yazılan uyarı/hata satırlarının sayısını okur. Gerçek komut çalıştırılıp doğrulandı: qpdf, "checking
/// ..." gibi bilgi satırlarını STDOUT'a, "WARNING: ..." / "qpdf: ... özet" satırlarını STDERR'e
/// yazıyor; çıkış kodu 0=temiz, 3=uyarılarla başarılı, 2=hata (diğer tüm qpdf çağrılarıyla aynı
/// sözleşme).
public enum RepairVerification {
  public struct Diagnosis: Sendable, Equatable {
    public let exitStatus: Int32
    /// stderr'deki boş olmayan satır sayısı — "kaç uyarı/hata" için kullanılan yaklaşık ölçüt.
    public let issueLineCount: Int
    public var hasIssues: Bool { exitStatus != 0 }
  }

  public static func diagnose(qpdf: URL, url: URL) async throws -> Diagnosis {
    let result = try await ProcessRunner.run(qpdf, arguments: ["--check", url.path])
    let lines = result.stderr.split(separator: "\n", omittingEmptySubsequences: true)
    return Diagnosis(exitStatus: result.status, issueLineCount: lines.count)
  }

  /// Onarım sonrası çıktının GERÇEKTEN daha iyi durumda olduğunu ölçer: ya uyarı/hata satır sayısı
  /// azalmış, ya da (satır sayısı aynı kalsa bile) durum "sorunlu"dan "temiz"e geçmiş olmalı — yalnız
  /// satır sayısına bakmak, itemize edilmemiş tek bir özet satırı taşıyan durumları kaçırabilirdi.
  public static func improved(before: Diagnosis, after: Diagnosis) -> Bool {
    after.issueLineCount < before.issueLineCount || (before.hasIssues && !after.hasIssues)
  }
}
