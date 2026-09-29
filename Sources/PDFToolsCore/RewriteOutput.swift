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

    /// Ölçülemeyen eksenler. Boş envanter + boş uyarı = "ölçtüm, temiz"; envanter okunamadıysa
    /// buraya bir cümle düşer, çünkü "ölçemedim" ile "sorun yok" AYNI ŞEY DEĞİLDİR (2026-09-29
    /// bağımsız inceleme bulgusu: eski kod ikisini de boş raporla aynı gösteriyordu).
    public let warnings: [String]

    public init(changes: [String], warnings: [String] = []) {
      self.changes = changes
      self.warnings = warnings
    }

    /// Sonuç satırına eklenecek cümle(ler) (söylenecek bir şey yoksa `nil`).
    public var note: String? {
      var parts: [String] = []
      if !changes.isEmpty {
        parts.append("redrawing changed the file: " + changes.joined(separator: " · "))
      }
      parts.append(contentsOf: warnings)
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    guard let before, let after else {
      // FAIL-OPEN DELİĞİ KAPATILDI (2026-09-29 bağımsız inceleme): envanter okunamadığında eski
      // kod `Report(changes: [])` ile SESSİZCE dönüyordu ve altındaki sayfa-sayısı kapısı HİÇ
      // çalışmıyordu — yani `SearchablePDFOperation`/`QRAddOperation` gibi kendi sayfa kontrolü
      // OLMAYAN işlemlerde eksik sayfalı çıktı bu delikten geri sızabilirdi. Envanter (üstveri
      // kıyası) pahalı ve kırılgan; sayfa SAYISI ise `--show-npages` ile ucuz ve bağımsız
      // ölçülebiliyor. Bu yüzden envanter düşerse kapı kapanmaz, DAHA BASİT bir ölçümle sürer;
      // o da ölçülemezse "doğrulanamadı" diye FIRLATIR, sessizce geçmez.
      let sourcePages = await Self.pageCount(of: source, qpdf: qpdf)
      let outputPages = await Self.pageCount(of: output, qpdf: qpdf)
      guard let sourcePages, let outputPages else {
        throw OperationError.pageIntegrityUnverifiable(
          "content inventory and page count could both not be read")
      }
      guard sourcePages == outputPages else {
        throw OperationError.redrawLostPages(before: sourcePages, after: outputPages)
      }
      return Report(
        changes: [], warnings: ["content inventory could not be compared (page count verified)"])
    }
    // SERT KAPI (2026-09-29, sessiz-hata denetimi): `SearchablePDFOperation`/`OCROperation` gibi
    // sayfa sayfa yeniden çizen işlemlerde bir sayfa açılamayıp döngü sessizce `continue` ederse
    // çıktı EKSİK SAYFALI oluyordu ve bunu yakalayan hiçbir kapı yoktu (yalnız `PageNumberOperation`/
    // `WatermarkAddOperation` KENDİ `numberOfPages` kontrolünü `finish` çağrısından ÖNCE yapıyordu —
    // bu yüzden onlarda zaten SIFIRDIR ve bu kapı orada sessizce hiç tetiklenmez). Burada eklenmesi
    // `RewriteOutput.finish` KULLANAN HER işlemi (bugünkü VE gelecekteki) tek yerden korur.
    guard after.pageCount == before.pageCount else {
      throw OperationError.redrawLostPages(before: before.pageCount, after: after.pageCount)
    }
    return Report(changes: after.differences(from: before))
  }

  /// Sayfa sayısını envanterden BAĞIMSIZ ölçer (`qpdf --show-npages`). Fırlatmaz: ölçülemediğinde
  /// `nil` döner ve kararı çağırana bırakır (çağıran bunu "doğrulanamadı" sayıp fırlatıyor).
  /// Yol `QPDFArgument.path` ile veriliyor: qpdf'in `--`'si tekil komutlarda İŞE YARAMIYOR
  /// (ölçüldü, bkz. `PDFEngine.swift`), ölçülmüş tek koruma `./` ön eki.
  private static func pageCount(of url: URL, qpdf: URL) async -> Int? {
    guard
      let result = try? await ProcessRunner.run(
        qpdf, arguments: ["--show-npages", QPDFArgument.path(for: url)]),
      result.status == 0 || result.status == 3
    else { return nil }
    return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
