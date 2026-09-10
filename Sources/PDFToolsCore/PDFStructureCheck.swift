import Foundation

/// Bir PDF'in İSKELETİNİ denetler: çapraz başvuru tablosu (xref) nesneleri gerçekten bulundukları
/// yerde mi gösteriyor, dosya katı bir ayrıştırıcı için sağlam mı. İçeriğe (piksele, kutuya)
/// BAKMAZ — onu `TrimVerification` yapıyor.
///
/// NEDEN VAR (saha arızası, 2026-09-10). "Kesim Payını At" çıktısı Preview'da sorunsuz açılıyordu,
/// kendi kapımız da "temiz" diyordu; ama çıktının xref tablosunda onlarca nesne "offset 0" ile
/// kayıtlıydı — yani "dosyanın 0. baytında", orada PDF başlığı var. qpdf ve Preview bunu sessizce
/// onarıp açıyor, KATI okuyucular açmıyor: kullanıcının Ghostscript tabanlı dizgi sistemi dosyayı
/// "Rebuild failed: Dictionary key 16 is not a name" ile reddetti. Ders: "açılıyor" kanıt değildir,
/// üstelik en tehlikeli arıza türü — bir okuyucuda çalışıp diğerinde çalışmayan çıktı.
///
/// Motor: paketlenmiş `qpdf --check`. Kendi ayrıştırıcımızı yazmıyoruz; qpdf bu işin referans
/// uygulaması ve zaten pakette (ölçüldü: 18 MB dosyada 0,14 sn — kapı olarak ucuz).
public enum PDFStructureCheck {
  public struct Result: Sendable, Equatable {
    /// xref'te "offset 0" ile kayıtlı nesne sayısı (0 olmalı).
    public let brokenOffsets: Int
    /// qpdf'in HATA olarak bildirdiği satırlar (uyarılar değil).
    public let errors: [String]

    public var isSound: Bool { brokenOffsets == 0 && errors.isEmpty }

    /// Kullanıcıya gösterilecek tek satırlık gerekçe.
    public var summary: String {
      var parts: [String] = []
      if brokenOffsets > 0 {
        parts.append("\(brokenOffsets) objects have a broken cross-reference offset")
      }
      if let first = errors.first { parts.append(first) }
      return parts.isEmpty ? "structure is sound" : parts.joined(separator: " · ")
    }

    public init(brokenOffsets: Int, errors: [String]) {
      self.brokenOffsets = brokenOffsets
      self.errors = errors
    }
  }

  /// Dosyayı qpdf ile YENİDEN YAZAR (yapı normalleştirme). Nesne içerikleri kopyalanır, yalnız
  /// iskelet (xref, nesne akışları) qpdf'in yazdığı biçimde kurulur — kırık offset'ler bu adımda
  /// düzelir. Sayfaları zaten yeniden çizen kip için ek kayıp YOK; kayıpsız kipte GEREKSİZ
  /// (`QPDFTrimEngine` çıktısını qpdf'in kendisi yazıyor) ve o yüzden orada çağrılmıyor.
  public static func repair(_ url: URL, qpdf: URL) async throws {
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).repair.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: temporary)
    let result = try await ProcessRunner.run(qpdf, arguments: [url.path, temporary.path])
    guard result.status == 0 || result.status == 3, fm.fileExists(atPath: temporary.path) else {
      try? fm.removeItem(at: temporary)
      return
    }
    _ = try? fm.replaceItemAt(url, withItemAt: temporary)
    try? fm.removeItem(at: temporary)
  }

  public static func inspect(_ url: URL, qpdf: URL) async throws -> Result {
    let result = try await ProcessRunner.run(qpdf, arguments: ["--check", url.path])
    return parse(output: result.stdout + "\n" + result.stderr, status: result.status)
  }

  /// Ayrıştırma `inspect`ten AYRI ve test edilebilir: kapının hangi satırı hata sayıp hangisini
  /// saydığı bu projede bir karar, alt sürecin kaprisi değil.
  static func parse(output: String, status: Int32) -> Result {
    var brokenOffsets = 0
    var errors: [String] = []
    for rawLine in output.split(separator: "\n") {
      let line = String(rawLine)
      if line.contains("object has offset 0") {
        brokenOffsets += 1
        continue
      }
      // Paketlediğimiz qpdf ikilisi JPEG akışlarını çözmeye çalışırken kendi kütüphane sürüm
      // uyuşmazlığını bildiriyor ("Wrong JPEG library version: library is 62, caller expects 80").
      // Bu DOSYANIN değil BİZİM ikilimizin özelliği (packaging/build-engines.sh ile derlenmiş
      // sürümde ölçüldü) — dosyayı suçlamaz, aksi halde JPEG içeren her sağlam PDF reddedilirdi.
      if line.contains("Wrong JPEG library version") || line.contains("will be re-processed") {
        continue
      }
      if line.hasPrefix("ERROR") || line.contains("ERROR:") {
        errors.append(line.trimmingCharacters(in: .whitespaces))
      }
    }
    // qpdf sözleşmesi: 0 = temiz, 3 = uyarılarla başarılı, 2 = hata. Hata koduyla döndüğü hâlde
    // ayrıştırılabilir bir ERROR satırı bulamadıysak yine de sağlam DEMEYİZ.
    if status != 0 && status != 3 && errors.isEmpty {
      errors.append("qpdf --check reported a damaged file (code \(status))")
    }
    return Result(brokenOffsets: brokenOffsets, errors: errors)
  }
}
