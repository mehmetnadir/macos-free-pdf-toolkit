import CoreGraphics
import Foundation

/// "Filigran Ekle" çıktısının GERÇEKTEN beklenen bölgede filigran bıraktığını ölçer — kendi çizim
/// kodumuza (`WatermarkAddOperation`) güvenmez. Yöntem `TrimVerification`/`CompressVerification`
/// ile AYNI üslup: sayfayı render edip beklenen bölgedeki (konum: merkez/üst/alt) mürekkep oranını
/// KAYNAK ve ÇIKTI için AYRI AYRI ölçer, ÇIKTIDA GERÇEKTEN artış olduğunu doğrular — kutu/metin
/// üstverisine değil render edilen piksele bakar.
///
/// SATÜRASYON ARIZASI VE DÜZELTME (2026-09-29, gerçek dosyalarla ölçüldü). Bu ikili "mürekkep
/// var/yok" (luma eşiği) ölçümü YOĞUN/renkli sayfalarda SATÜRE oluyor: bölge zaten neredeyse
/// tamamen "mürekkepli" sayılan piksellerle doluyken üstüne %15 opaklıkla gri bir filigran
/// eklemek, eşiği ZATEN aşmış pikselleri tekrar mürekkepli saydırmıyor. Üç gerçek dosyada
/// ölçülen fark: 6 sayfalık temiz bir dosyada %6,66→%6,98 (fark %0,31 — eski eşiği %0,3'ü
/// güç bela geçiyordu), 9 sayfalık renkli bir çalışma kitabında %92,79→%92,91 (fark %0,12),
/// 376 sayfalık bir soru bankasında %88,59→%88,62 (fark %0,03) — SON İKİSİNDE filigran
/// GERÇEKTEN çizilmişti (bkz. `WatermarkStructuralCheck` ile bağımsız doğrulama) ama piksel
/// eşiği bunu görmüyordu. Bu yüzden bu ölçüm artık TEK BAŞINA kapı DEĞİL: birincil kanıt
/// `WatermarkStructuralCheck` (çıktının içerik akışında GERÇEKTEN bir metin gösterme operatörü
/// var mı), bu piksel ölçümü İKİNCİL/doğrulayıcı sinyal olarak kalıyor (çıktı-kaynak farkının
/// SIFIR OLMADIĞINI doğrular — bkz. `WatermarkAddOperation.run` Kanıt 2).
public enum WatermarkVerification {
  public static let renderDPI: CGFloat = 150
  /// Bu luma değerinin (0-255, gri tonlama) altı "mürekkep var" sayılır — `CompressVerification`'ın
  /// "raster" kademesi için kullandığı eşikle AYNI (bkz. o dosyadaki gerekçe).
  private static let inkLumaThreshold: UInt8 = 250
  /// ESKİ (artık TEK BAŞINA kullanılmayan) eşik — bkz. dosya üstü SATÜRASYON notu. Yalnız
  /// `Tur7Tests`'in beyaz/temiz sentetik fixture'ında bağımsız bir sağlama olarak hâlâ
  /// kullanılıyor; `WatermarkAddOperation.run`'ın ÜRETİM kapısı artık bunu KULLANMIYOR (bkz.
  /// `WatermarkStructuralCheck` + bu dosyadaki `structuralEvidence`).
  public static let minDeltaPercent: Double = 0.3

  /// `position`'a göre incelenecek NORMALİZE (0...1, PDF orijini SOL-ALT) bölge.
  /// `WatermarkAddOperation` ile aynı üç konumu kapsar; "center" çapraz metnin sayfa ortasından
  /// GEÇTİĞİ geniş bir bölgedir.
  public static func region(for position: String) -> CGRect {
    switch position {
    case "header": return CGRect(x: 0.05, y: 0.8, width: 0.9, height: 0.2)
    case "footer": return CGRect(x: 0.05, y: 0.0, width: 0.9, height: 0.2)
    default: return CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)  // "center" (çapraz)
    }
  }

  /// `url`'in `pageIndex` (1-tabanlı) sayfasını render edip `region` içindeki mürekkep yüzdesini
  /// döner. Sayfa/döküman açılamazsa ya da kutusu dejenereyse `nil`.
  public static func inkPercent(pdfAt url: URL, pageIndex: Int, region: CGRect) -> Double? {
    guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: pageIndex) else {
      return nil
    }
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = renderDPI / 72.0
    let pxWidth = max(1, Int((box.width * scale).rounded()))
    let pxHeight = max(1, Int((box.height * scale).rounded()))
    guard
      let ctx = CGContext(
        data: nil, width: pxWidth, height: pxHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let data = ctx.data else { return nil }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * pxHeight)

    // Satır 0 = görüntünün ÜSTÜ (bkz. `TrimVerification` aynı ölçülmüş not) — normalize bölgenin
    // ÜST sınırı (region.maxY, daha büyük y) daha KÜÇÜK satır indeksine karşılık gelir.
    let rowTop = max(0, Int(((1 - region.maxY) * CGFloat(pxHeight)).rounded()))
    let rowBottom = min(pxHeight, Int(((1 - region.minY) * CGFloat(pxHeight)).rounded()))
    let colLeft = max(0, Int((region.minX * CGFloat(pxWidth)).rounded()))
    let colRight = min(pxWidth, Int((region.maxX * CGFloat(pxWidth)).rounded()))
    guard rowTop < rowBottom, colLeft < colRight else { return 0 }

    var total = 0
    var ink = 0
    for row in rowTop..<rowBottom {
      let rowStart = row * bytesPerRow
      for col in colLeft..<colRight {
        total += 1
        if buffer[rowStart + col] < inkLumaThreshold { ink += 1 }
      }
    }
    return total == 0 ? 0 : Double(ink) / Double(total) * 100
  }

  /// Kaynak ile çıktının AYNI bölgesindeki mürekkep oranını kıyaslar (çıktı − kaynak). Biri
  /// açılamazsa `nil` — çağıran bunu "ölçülemedi" olarak ayrı ele alır, sessizce başarılı SAYMAZ.
  public static func delta(
    sourceURL: URL, outputURL: URL, pageIndex: Int, position: String
  ) -> Double? {
    let r = region(for: position)
    guard let sourcePercent = inkPercent(pdfAt: sourceURL, pageIndex: pageIndex, region: r),
      let outputPercent = inkPercent(pdfAt: outputURL, pageIndex: pageIndex, region: r)
    else { return nil }
    return outputPercent - sourcePercent
  }

  // MARK: - Yapısal kanıt (BİRİNCİL — bkz. dosya üstü SATÜRASYON notu)

  /// `outputURL`'in `pageIndex` (1-tabanlı) sayfasının İÇERİK AKIŞINDA, `position`'a UYGUN
  /// GERÇEK bir metin gösterme operatörü var mı. `WatermarkStructuralCheck.analyze` ile
  /// akışın EN SON `BT...ET` bloğunu (kaynak sayfa ne kadar karmaşık olursa olsun HER ZAMAN
  /// bizim filigranımız — bkz. o dosyanın üst yorumu) inceler.
  ///
  /// qpdf bulunamazsa ya da sayfa/akış okunamazsa `nil` — çağıran bunu "doğrulanamadı" sayıp
  /// FAIL-CLOSED davranmalı (bkz. proje geneli Silent Catch Gate ilkesi: ölçüm yapılamadığında
  /// "geçti" değil "düştü" denir).
  public static func structuralTextWasDrawn(
    outputURL: URL, pageIndex: Int, position: String, qpdf: URL
  ) async throws -> Bool? {
    guard let bytes = try await pageContentStreamBytes(outputURL, pageIndex: pageIndex, qpdf: qpdf)
    else { return nil }
    guard let evidence = WatermarkStructuralCheck.analyze([UInt8](bytes)) else { return false }
    guard evidence.textWasShown else { return false }

    switch position {
    case "header", "footer":
      guard let ty = evidence.textMatrixTY,
        let height = pageHeight(of: outputURL, pageIndex: pageIndex)
      else { return false }
      return position == "header" ? ty > height / 2 : ty < height / 2
    default:  // "center" — çapraz, 45° döndürme bekleniyor.
      return WatermarkStructuralCheck.looksLikeDiagonalRotation(evidence.rotation)
    }
  }

  private static func pageHeight(of url: URL, pageIndex: Int) -> Double? {
    guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: pageIndex)
    else { return nil }
    return Double(page.getBoxRect(.mediaBox).height)
  }

  /// `pageIndex` (1-tabanlı) sayfasının TÜM `/Contents` akışlarını (tek akış ya da dizi olabilir
  /// — PDF32000 7.8.2 ardışık akışları boşlukla BİRLEŞTİRİR) qpdf JSON ile okur. Yalnız İLGİLİ
  /// nesneler istenir (`--json-object`), `--json-stream-data=inline` genel filtreleri (Flate
  /// vb.) ÇÖZER — `PDFContentInventory`/`QPDFPageEditor` ile AYNI "ucuz, hedefli qpdf JSON"
  /// deseni: koca belgeyi patlatmaz (376 sayfalık, kırık offset'li bir dosyada bile tek
  /// sayfanın akışı saniyenin altında okundu).
  static func pageContentStreamBytes(_ url: URL, pageIndex: Int, qpdf: URL) async throws -> Data? {
    let pagesResult = try await ProcessRunner.run(
      qpdf, arguments: ["--json=latest", "--json-key=pages", url.path])
    guard pagesResult.status == 0 || pagesResult.status == 3,
      let pagesData = pagesResult.stdout.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: pagesData) as? [String: Any],
      let pages = root["pages"] as? [[String: Any]],
      pageIndex >= 1, pageIndex <= pages.count
    else { return nil }
    guard let contentRefs = pages[pageIndex - 1]["contents"] as? [String], !contentRefs.isEmpty
    else { return nil }

    var arguments = ["--json=latest", "--json-key=qpdf", "--json-stream-data=inline"]
    arguments += contentRefs.map { ref in
      "--json-object=\(ref.split(separator: " ").first.map(String.init) ?? ref)"
    }
    arguments.append(url.path)
    let result = try await ProcessRunner.run(qpdf, arguments: arguments)
    guard result.status == 0 || result.status == 3,
      let data = result.stdout.data(using: .utf8),
      let objRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let container = objRoot["qpdf"] as? [Any], container.count >= 2,
      let objects = container[1] as? [String: Any]
    else { return nil }

    var combined = Data()
    for ref in contentRefs {
      guard let entry = objects["obj:\(ref)"] as? [String: Any],
        let stream = entry["stream"] as? [String: Any],
        let base64 = stream["data"] as? String,
        let bytes = Data(base64Encoded: base64)
      else { continue }
      combined.append(bytes)
      combined.append(0x20)  // PDF32000 7.8.2: ardışık akışlar boşlukla birleştirilir
    }
    return combined.isEmpty ? nil : combined
  }
}
