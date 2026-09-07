import CoreGraphics
import Foundation
import Vision

/// "QR Ekle" ve "QR Ayıkla" işlemlerinin PAYLAŞTIĞI tarama çekirdeği: bir PDF sayfasını `dpi`'de
/// beyaz zemin üstüne render edip `VNDetectBarcodesRequest` ile üstündeki QR kodlarını okur.
/// Harici motor YOK — yalnız Apple'ın yerleşik Vision çerçevesi (bkz. dosya üstü render deseni,
/// `ImageExportOperation.renderPage` ile aynı CoreGraphics üslubu).
///
/// ÖLÇÜLMÜŞ KRİTİK BULGU (gerçek üretim kitabı, https://yds.tc/ydsdigital): Vision'ın QR tespiti
/// 100 dpi'da bu kitapta 0 QR buldu (hata FIRLATMADI — sessizce "yok" ile ayırt edilemez sonuç
/// verdi), 150 ve 200 dpi'da doğru okudu. Bu yüzden bu API'de varsayılan/kullanılan dpi hiçbir
/// zaman 100'ün altına düşürülmemeli — `QRAddOperation` doğrulaması sabit 200 dpi kullanır,
/// `QRExtractOperation` seçeneklerinde 100 dpi HİÇ sunulmaz (bkz. o dosyadaki aynı not).
///
/// AYRICA ÖLÇÜLDÜ (bkz. `Tur5Tests.testQRAddAndExtractTurkishAndLongContent` yorumu): çok uzun
/// içerikte (200+ karakter), tam uzunluk o QR versiyonunun veri kapasite sınırına ÇOK yakınsa,
/// Vision'ın çözücüsü (yalnız `xctest` çalıştırıcısı altında görüldü — muhtemelen ANE/CPU geri
/// düşüş farkı; bağımsız derlenmiş bir ikilide AYNI içerik hep birebir okundu) hata düzeltmesini
/// "geçerli ama YANLIŞ" bir koda yuvarlayıp son karakteri sessizce düşürebiliyor. Bu,
/// `pageContains` dahil bu API'nin sıradan (kapasiteden uzak) içerikler için GÜVENİLMEZ olduğu
/// anlamına gelmez — yalnızca versiyon sınırına yapışık, aşırı yoğun içerikte bilinen bir
/// kırılganlık.
public enum QRVerification {
  /// Tek bir QR tespitinin sonucu.
  public struct Detection: Sendable, Equatable {
    /// Çözülen metin (payload).
    public let payload: String
    /// Vision'ın normalize edilmiş sınırlayıcı kutusu: orijin SOL-ALT, 0...1 aralığında
    /// (CoreGraphics/PDF sayfa uzayıyla aynı yön kuralı — ölçüldü, bkz. scratchpad ölçümü).
    public let boundingBox: CGRect
  }

  /// `page`'i `dpi`'de render edip üstündeki TÜM QR kodlarının tespitlerini döner (bulunamazsa
  /// boş dizi). Sayfa kutusu dejenereyse ya da render başarısızsa yine boş dizi — bu fonksiyon
  /// hata FIRLATMAZ, "bulunamadı" ile "render edilemedi" arasındaki farkı çağıran taraf umursamaz.
  public static func detections(onPage page: CGPDFPage, dpi: CGFloat) -> [Detection] {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return [] }
    let scale = dpi / 72.0
    let width = max(1, Int((box.width * scale).rounded(.up)))
    let height = max(1, Int((box.height * scale).rounded(.up)))
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return [] }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    guard let image = ctx.makeImage() else { return [] }

    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      return []
    }
    return (request.results ?? []).compactMap { observation in
      guard let payload = observation.payloadStringValue else { return nil }
      return Detection(payload: payload, boundingBox: observation.boundingBox)
    }
  }

  /// `detections(onPage:dpi:)` ile aynı, yalnızca çözülen metinleri döner — `QRExtractOperation`'ın
  /// kullandığı kısayol.
  public static func detectedPayloads(onPage page: CGPDFPage, dpi: CGFloat) -> [String] {
    detections(onPage: page, dpi: dpi).map(\.payload)
  }

  /// `url`'deki PDF'in `pageIndex` (1-tabanlı) sayfasında `expectedContent`'e TAM OLARAK eşit bir
  /// QR var mı diye bakar. Döküman/sayfa açılamazsa `false` — `QRAddOperation`'ın üretim çıktısını
  /// kapatan asıl kanıt budur ("QR çizildi ama okunmuyor" hatasını yakalar).
  public static func pageContains(
    pdfAt url: URL, pageIndex: Int, expectedContent: String, dpi: CGFloat = 200
  ) -> Bool {
    guard let document = CGPDFDocument(url as CFURL), document.isUnlocked,
      let page = document.page(at: pageIndex)
    else { return false }
    return detectedPayloads(onPage: page, dpi: dpi).contains(expectedContent)
  }
}
