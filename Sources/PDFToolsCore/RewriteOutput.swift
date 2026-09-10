import Foundation

/// Sayfaları YENİDEN ÇİZEN işlemlerin ortak son adımı (sayfa numarası, QR ekle, filigran ekle,
/// aranabilir yap, kesimin "remove" kipi). Üç şey yapar: xref'i onarır, sağlamlığını KANITLAR,
/// yeniden çizmenin kaynakta neyi değiştirdiğini SÖYLENEBİLİR hâle getirir.
///
/// NEDEN VAR (2026-09-10 saha arızası + süpürme). Kesim payı arızasının kökü CoreGraphics ile
/// sayfa yeniden çizmekti; süpürmede AYNI hasarın kardeş işlemlerde de durduğu ölçüldü. Gerçek bir
/// matbaa dosyasında (3,7 MB, 130 sayfa) çıktılar:
///   · Sayfa Numarası Ekle → xref'te 64 nesne "offset 0", sürüm 1.4→1.3, 7 XMP akışı silinmiş,
///     86 `/DeviceGray` görüntünün 57'si `/ICCBased`e dönmüş
///   · QR Ekle → 64 kırık offset, aynı tablo
///   · Aranabilir Yap → 5 kırık offset, aynı tablo
/// Yani kullanıcının "gs tabanlı sistem dosyayı reddediyor" şikâyeti kesime özgü DEĞİLDİ; sayfa
/// numarası eklemek de aynı reddi üretiyordu. Bu adım o sınıfı kapatıyor.
///
/// SINIRI: onarım xref'i düzeltir, yeniden çizmenin renk/üstveri hasarını GERİ ALMAZ — onun tek
/// gerçek çözümü sayfayı hiç yeniden çizmemek (kesimde yapıldı; damgalayan işlemler için pdfcpu
/// damgası ayrı bir iş). Bu yüzden hasar burada ölçülüp ÇAĞIRANA döndürülüyor: sessizce
/// yutulmasın, sonuç satırında kullanıcıya söylenebilsin.
public enum RewriteOutput {
  public struct Report: Sendable {
    /// Yeniden çizmenin kaynağa göre değiştirdikleri (boşsa içerik envanteri korunmuş).
    public let changes: [String]

    /// Sonuç satırına eklenecek tek cümle (değişiklik yoksa `nil`).
    public var note: String? {
      changes.isEmpty ? nil : "redrawing changed the file: " + changes.joined(separator: " · ")
    }
  }

  /// `output`u yerinde onarır ve doğrular. Yapı onarımdan sonra da bozuksa
  /// `OperationError.outputStructureBroken` fırlatır — çağıran çıktıyı SİLMELİ.
  ///
  /// qpdf bulunamazsa (paketleme arızası) boş rapor döner: bu adım bir EK güvence, işlemin
  /// kendi doğrulama kapısının yerine geçmiyor.
  public static func finish(output: URL, source: URL) async throws -> Report {
    guard let qpdf = EngineLocator.find("qpdf") else { return Report(changes: []) }
    try await PDFStructureCheck.repair(output, qpdf: qpdf)
    let structure = try await PDFStructureCheck.inspect(output, qpdf: qpdf)
    guard structure.isSound else {
      throw OperationError.outputStructureBroken(structure.summary)
    }
    let before = try? await PDFContentInventory.read(source, qpdf: qpdf)
    let after = try? await PDFContentInventory.read(output, qpdf: qpdf)
    guard let before, let after else { return Report(changes: []) }
    return Report(changes: after.differences(from: before))
  }
}
