import CoreGraphics
import Foundation

/// CoreGraphics tabanlı kesim (trim) motoru — Ghostscript'e alt-süreç GEREKTİRMEYEN varsayılan
/// alternatif. Her sayfa için yeni bir PDF sayfası açılır (`beginPDFPage`), MediaBox TrimBox'a
/// (yoksa MediaBox'ın kendisine — bkz. `outputBox(for:)` yorumu) küçültülür, içerik bu kutuya
/// `clip(to:)` ile kırpılır ve `drawPDFPage` ile çizilir.
///
/// NEDEN VARSAYILAN (ölçüldü, 2026-09-09): gerçek bir kitapta (3 sayfa, 5mm kesim payı) üç yol
/// karşılaştırıldı — Ghostscript kutu-dışı kalıntı %0,00 / kesim-içi piksel farkı 4,02/255,
/// pdfcpu boxes kalıntı %11,65 (içerik SİLİNMİYOR, yalnız kutu üstverisi küçülüyor), CoreGraphics
/// kalıntı %0,00 / piksel farkı 0,03/255 — yani CoreGraphics gs kadar temiz VE ondan DAHA sadık,
/// lisans sorunu yok (AGPL değil), kurulum gerektirmiyor. Ghostscript `GhostscriptEngine.swift`da
/// kullanılabilir kalmaya devam ediyor (`EngineLocator.ghostscript()` üzerinden ayrı erişilir) —
/// yalnızca `EngineLocator.trimEngine()`'in TERCİHİ değişti.
///
/// DÖNDÜRME (bkz. `.claude/docs/…` — ilk prototipin bilinen kusuru): `ctx.drawPDFPage(page)`
/// sayfanın `/Rotate` üstverisini YOK SAYAR (bkz. `PageThumbnailCache.swift` aynı notu) — transform
/// concatenate edilmeden çizilirse içerik her zaman ham (rotasyonsuz) sayfa uzayında çıkar. Ayrıca
/// `CGPDFContext` sayfa sözlüğü (`beginPDFPage` pageInfo) yalnız MediaBox/CropBox/BleedBox/TrimBox/
/// ArtBox anahtarlarını kabul eder (`CGPDFContext.h`, kontrol edildi) — çıktı sayfasına elle
/// `/Rotate` YAZILAMAZ. Bu yüzden rotasyon METADATA olarak taşınmıyor, İÇERİĞE PİŞİRİLİYOR:
/// `CGPDFPage.getDrawingTransform(.trimBox, rect:, rotate: 0, preserveAspectRatio:)` kaynağın
/// KENDİ `/Rotate` açısını (rotate:0 yalnızca EKSTRA döndürme eklemediğimiz anlamına gelir, sayfanın
/// öz açısı yine uygulanır) hedef dikdörtgene göre çözüp doğru transformu üretir — çıktı sayfası
/// zaten doğru yönde çizilir ve kendi `/Rotate`'i 0 kalır (gerek kalmaz). Kutunun EN/BOY'u da bu
/// yüzden 90/270'te TAKAS edilir (`outputBox(for:)`): görsel (rotasyon uygulanmış) boyut neyse çıktı
/// kutusu odur.
public struct CoreGraphicsTrimEngine: TrimEngine {
  public let name = "CoreGraphics"
  /// `TrimEngine.executable` sözleşmesi bir alt-süreç ikilisi ister; bu motor süreç-içi (in-process)
  /// çalıştığından gerçek bir ikili YOK. Çağıranların (ör. `pdftools engines` teşhis komutu, hata
  /// mesajları) motoru işaret edebilmesi için sistemde her zaman var olan, zararsız bir yer tutucu
  /// veriyoruz — bu URL asla `ProcessRunner`a geçirilmiyor (bu motorda alt-süreç çağrısı YOK).
  public let executable = URL(fileURLWithPath: "/System/Library/Frameworks/CoreGraphics.framework")

  public init() {}

  public func trim(
    input: URL, output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    progress(0)
    guard let document = CGPDFDocument(input as CFURL), document.isUnlocked else {
      throw EngineError.failed(status: -1, message: "PDF could not be opened: \(input.lastPathComponent)")
    }
    let total = document.numberOfPages
    guard total > 0, let firstPage = document.page(at: 1) else {
      throw EngineError.failed(status: -1, message: "PDF has no pages: \(input.lastPathComponent)")
    }

    // Belge-seviyesi mediaBox yalnız BAŞLANGIÇ değeri; her sayfa aşağıdaki döngüde kendi kutusunu
    // `beginPDFPage`'e ayrıca veriyor (sayfadan sayfaya FARKLI TrimBox desteği bu sayede çalışıyor).
    var documentBox = Self.outputBox(for: firstPage)
    guard let consumer = CGDataConsumer(url: output as CFURL),
      let ctx = CGContext(consumer: consumer, mediaBox: &documentBox, nil)
    else {
      throw EngineError.failed(
        status: -1, message: "Output PDF context could not be created: \(output.lastPathComponent)")
    }

    for index in 1...total {
      guard let page = document.page(at: index) else { continue }
      var pageBox = Self.outputBox(for: page)
      // ÖNEMLİ (ölçüldü, 2026-09-09 — gerçek bir kusuru düzeltiyor): `kCGPDFContextMediaBox`'ın
      // değeri `CGPDFContext.h`'ye göre "CFData containing a CGRect (stored by value, not by
      // reference)" olmalı — `NSValue(rect:)` bu sözleşmeyi KARŞILAMAZ ve CoreGraphics onu sessizce
      // YOK SAYAR: ölçüldü, `NSValue` verildiğinde 2. ve sonraki sayfalar 1. sayfanın kutusunu
      // (belgenin başlangıç `mediaBox`'ını) MİRAS ALIYOR — sayfadan sayfaya FARKLI TrimBox desteği
      // SESSİZCE bozuluyordu. Doğru biçim `TrimTests.swift`'in TrimBox fixture'ında zaten
      // kullanılan `Data(bytes:count:)` kalıbıyla AYNI.
      let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
      let pageInfo = [kCGPDFContextMediaBox as String: boxData as CFData] as CFDictionary
      ctx.beginPDFPage(pageInfo)
      ctx.saveGState()
      // Kırpma ZORUNLU: `clip(to:)` olmadan vektör içerik kutunun dışına taşabilir (bkz.
      // `TrimVerification` gate yorumu) — kutu üstverisini küçültmek TEK BAŞINA yetmez.
      ctx.clip(to: pageBox)
      let transform = page.getDrawingTransform(
        .trimBox, rect: pageBox, rotate: 0, preserveAspectRatio: true)
      ctx.concatenate(transform)
      ctx.drawPDFPage(page)
      ctx.restoreGState()
      ctx.endPDFPage()
      progress(Double(index) / Double(total))
    }
    ctx.closePDF()
    progress(1)
  }

  /// Bir sayfanın kesim SONRASI çıktı kutusu. Kaynak: `getBoxRect(.trimBox)` — sayfada açık bir
  /// `/TrimBox` YOKSA CoreGraphics bunu otomatik olarak `/MediaBox`'a düşürür (bu davranış
  /// `PDFFileInfo.inspect`'te zaten kullanılıyor: `boxesDiffer(rawTrimBox, mediaBox)` ile "gerçek
  /// trimBox yok" tespiti oradan yapılıyor) — yani TrimBox'ı olmayan sayfada bu fonksiyon MediaBox'ı
  /// döndürür ve sayfa fiilen KIRPILMADAN geçer (görev şartı #3).
  ///
  /// Köken her zaman (0,0): `getDrawingTransform` içeriği bu dikdörtgene ORTALAYIP ölçekler,
  /// TrimBox'ın orijinal mutlak koordinatlarının çıktıda hiçbir anlamı yok.
  ///
  /// EN/BOY TAKASI: sayfanın `/Rotate`'i 90 ya da 270 ise GÖRSEL (ekranda görünen) boyut, kutunun
  /// kendi ham boyutundan ters orandadır — çıktı kutusu görsel boyutu yansıtmalı (bkz. dosya üstü
  /// döndürme notu).
  static func outputBox(for page: CGPDFPage) -> CGRect {
    let trimBox = page.getBoxRect(.trimBox)
    let rotation = normalizedRotation(page.rotationAngle)
    let rotated = rotation == 90 || rotation == 270
    let width = rotated ? trimBox.height : trimBox.width
    let height = rotated ? trimBox.width : trimBox.height
    return CGRect(x: 0, y: 0, width: width, height: height)
  }

  /// `/Rotate` değerini 0/90/180/270 aralığına normalize eder (negatif ya da 360 katları dahil).
  /// `PageEditVerification.normalizedDegree` ile AYNI mantık — o `private` olduğundan (ayrı
  /// dosya/tip) burada bilinçli olarak yeniden yazıldı, davranış birebir aynı.
  static func normalizedRotation(_ raw: Int32) -> Int {
    ((Int(raw) % 360) + 360) % 360
  }
}
