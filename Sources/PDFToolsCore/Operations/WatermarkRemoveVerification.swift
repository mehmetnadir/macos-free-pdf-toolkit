import CoreGraphics
import Foundation

/// "Filigran Kaldır" (DENEYSEL) çıktısının doğruluğunu ölçer. `TrimVerification`/`MergeVerification`
/// ile aynı üslupta: kutu/metadata veya `note` metnine değil GERÇEĞE bakar.
///
/// İki ayrı kanıt, iki ayrı fonksiyon:
/// 1. `textReallyRemoved` (ASYNC — alt süreç gerektirir): hedef nesnenin akışı çıktıda
///    GERÇEKTEN boşalmış mı — aynı içerik-akışı metin çıkarımı çıktı ÜZERİNDE TEKRAR
///    çalıştırılır. Bu, `TrimVerification`'ın "kutu üstverisine değil render'a güven" ilkesinin
///    karşılığıdır: yalnızca "işlem hata vermeden bitti" ile yetinmek, akışın aslında
///    boşalmadığı bir hatayı (ör. yanlış nesne referansı, `--update-from-json` sessizce no-op
///    yapması) sessizce "başarılı" raporlar.
/// 2. `verify` (SENKRON — yalnız CoreGraphics render): sayfa sayısı korunmuş mu + filigran
///    BÖLGESİ DIŞINDA ilk sayfa piksel piksel aynı mı (kaynak vs çıktı, 72 dpi gri tonlama).
///
/// VARSAYIM (belgelenmiş sınırlama — `verify`'ın filigran bölgesini nasıl bulduğuyla ilgili):
/// Form XObject'in sayfa uzayına YERLEŞTİRME dönüşümü (kendi `/Matrix`'i + çağrıldığı yerdeki
/// `cm`) TAKİP EDİLMEZ — tam bir içerik akışı yorumlayıcısı bu görevin kapsamı dışında bırakıldı
/// (bkz. görev notu "tam bir ayrıştırıcı yazma"). Bunun yerine adayın KENDİ `BBox`'ı DOĞRUDAN
/// sayfa uzayında kabul edilir. Bu, ölçülen gerçek örnekle (`www.frenglish.ru`, BBox zaten
/// sayfa-benzeri koordinatlarda — `.claude/docs/yol-haritasi-2026-09.md` §1.2) ve bu turun test
/// fixture'ıyla (kimlik `/Matrix`, kimlik yerleştirme `cm`) tutarlıdır. Farklı yerleştirilmiş
/// (ör. ölçekli/döndürülmüş) bir filigranda bu bölge yanlış çıkabilir — v2'de gerçek CTM takibi
/// gerekir; o zamana kadar bu, yalnız "belirgin bozulma"yı (filigran dışı bir şey silinmiş/
/// bozulmuş) yakalamayı hedefleyen bir gate'tir, mükemmel bir bölge sınırlayıcı değil.
public enum WatermarkRemoveVerification {
  public enum Verdict: Sendable, Equatable {
    case clean
    case failed
  }

  public struct Result: Sendable, Equatable {
    public let verdict: Verdict
    public let reason: String
  }

  /// Bu oranın üstündeki (filigran DIŞI bölgedeki) piksel farkı "gerçek bozulma" sayılır.
  private static let mismatchThreshold: Double = 0.01
  private static let renderDPI: CGFloat = 72

  /// Hedef nesnenin akışının çıktıda GERÇEKTEN boşaldığını doğrular. ÖNEMLİ ÖLÇÜM NOTU
  /// (bu turda keşfedildi): `qpdf --update-from-json` bir dosya YAZARKEN nesneleri YENİDEN
  /// NUMARALANDIRIYOR — girişte `4 0 R` olan Form nesnesi çıktıda `12 0 R` olabilir, `4 0 R` ise
  /// tamamen FARKLI bir nesneye (ör. bir sayfa) düşebilir (gerçek qpdf denemesiyle doğrulandı).
  /// Bu yüzden `candidate.objectID`'yi ÇIKTIDA yeniden aramak YERİNE, çıktının TAMAMINI tekrar
  /// tara (`candidates(in:qpdfExecutable:)`) ve aynı metnin (ANLAMLI EŞLEŞME: metin dizisi)
  /// hâlâ bir aday olarak göründüğü olup olmadığına bak — bu, nesne kimliğinden BAĞIMSIZ ve
  /// gözlemlenebilir gerçek sonuca (metin belgede hâlâ tekrarlıyor mu) dayandığı için daha
  /// SAĞLAM: nesne numarası kaymasına karşı kırılgan değil. Alt süreç gerektirdiği için async —
  /// `verify(source:output:candidate:)`'dan bilerek AYRI (o saf CoreGraphics/senkron kalsın diye).
  public static func textReallyRemoved(
    candidate: WatermarkCandidate, output: URL, qpdfExecutable: URL
  ) async throws -> Bool {
    guard !candidate.extractedText.isEmpty else {
      // Metinsiz (taranmış/salt-vektör) bir adayda bu ölçüt anlamsız — arayan yalnızca piksel
      // doğrulamasına (`verify`) güvenmeli. "Reddetmeyelim" tarafında hata payı bırakılıyor.
      return true
    }
    let after = try await WatermarkRemoveOperation.candidates(in: output, qpdfExecutable: qpdfExecutable)
    return !after.contains { $0.extractedText == candidate.extractedText }
  }

  /// Sayfa sayısı + filigran-dışı piksel bütünlüğü kontrolü. `source`/`output` ilk sayfaları
  /// aynı DPI'da render edilip `candidate.bbox` DIŞINDAKİ piksellerde karşılaştırılır.
  public static func verify(
    source: URL, output: URL, candidate: WatermarkCandidate
  ) -> Result {
    guard let sourceDoc = CGPDFDocument(source as CFURL) else {
      return Result(verdict: .failed, reason: "source could not be opened")
    }
    guard let outputDoc = CGPDFDocument(output as CFURL) else {
      return Result(verdict: .failed, reason: "output could not be opened")
    }
    guard outputDoc.numberOfPages == sourceDoc.numberOfPages else {
      return Result(
        verdict: .failed,
        reason: "page count changed (\(sourceDoc.numberOfPages) → \(outputDoc.numberOfPages))")
    }
    guard let sourcePage = sourceDoc.page(at: 1), let outputPage = outputDoc.page(at: 1) else {
      return Result(verdict: .failed, reason: "first page could not be opened")
    }
    guard
      let sourceBitmap = render(sourcePage), let outputBitmap = render(outputPage),
      sourceBitmap.width == outputBitmap.width, sourceBitmap.height == outputBitmap.height
    else {
      return Result(verdict: .failed, reason: "could not render, or page sizes don't match")
    }

    let box = sourcePage.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else {
      return Result(verdict: .failed, reason: "page box is degenerate")
    }
    let scale = renderDPI / 72.0

    var total = 0
    var diff = 0
    for row in 0..<sourceBitmap.height {
      let userY = box.maxY - (Double(row) + 0.5) / Double(scale)
      let rowStart = row * sourceBitmap.width
      for col in 0..<sourceBitmap.width {
        let userX = box.minX + (Double(col) + 0.5) / Double(scale)
        // Filigran bölgesinin İÇİNDE kalan piksel karşılaştırmaya KATILMAZ — orada değişiklik
        // BEKLENİYOR (asıl silinen yer burası); asıl kanıt bölge DIŞINDA hiçbir şeyin
        // bozulmamış olmasıdır.
        guard !candidate.bbox.contains(CGPoint(x: userX, y: userY)) else { continue }
        total += 1
        let idx = rowStart + col
        if abs(Int(sourceBitmap.data[idx]) - Int(outputBitmap.data[idx])) > 10 { diff += 1 }
      }
    }

    let percent = total == 0 ? 0 : Double(diff) / Double(total)
    guard percent < mismatchThreshold else {
      let formatted = String(format: "%.2f", percent * 100)
      return Result(
        verdict: .failed,
        reason: "content outside the watermark changed (\(formatted)% difference)")
    }
    return Result(verdict: .clean, reason: "clean")
  }

  private struct Bitmap { let data: [UInt8]; let width: Int; let height: Int }

  private static func render(_ page: CGPDFPage) -> Bitmap? {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = renderDPI / 72.0
    let width = max(1, Int((box.width * scale).rounded(.up)))
    let height = max(1, Int((box.height * scale).rounded(.up)))
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let data = ctx.data else { return nil }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    var out = [UInt8](repeating: 0, count: width * height)
    for row in 0..<height {
      let rowStart = row * bytesPerRow
      for col in 0..<width { out[row * width + col] = buffer[rowStart + col] }
    }
    return Bitmap(data: out, width: width, height: height)
  }
}
