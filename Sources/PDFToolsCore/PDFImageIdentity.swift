import CoreGraphics
import CryptoKit
import Foundation

/// Sayfa başına gömülü görüntü akışlarının KİMLİĞİ: her `/XObject /Subtype /Image` akışının
/// `CGPDFStreamCopyData` baytlarının SHA-256'sı. Alt süreç YOK, yalnız CoreGraphics.
///
/// NEDEN VAR (aranabilir katman spec'i §2.5c, 2026-10-03). "Aranabilir Yap"ın `overlay` kipi
/// sayfayı yeniden ÇİZMEDİĞİNİ iddia ediyor; piksel kapısı bunu tek başına kanıtlayamaz (render
/// eden araç kendi renk yönetimine kördür — bkz. kesim payı arızası dersleri). Bu tip ikinci,
/// BAĞIMSIZ bir eksen verir: görüntü baytları kaynakla çıktıda aynı mı.
///
/// `qpdf --overlay` kaynak sayfanın içeriğini bir Form XObject'e (`/Fx0`) sarıyor (ölçüldü, qpdf
/// 12.4.1) — görüntü artık sayfanın değil formun kaynaklarında. Bu yüzden gezinti Form
/// XObject'lerin içine de iner (döngüye karşı derinlik sınırıyla).
public enum PDFImageIdentity {
  /// Form iç içe geçme sınırı — kötü niyetli/bozuk bir dosyadaki öz-başvuru döngüsünü keser.
  static let maxFormDepth = 8

  /// `page`'deki (ve kullandığı formlardaki) her görüntü akışını `body`'ye verir.
  static func forEachImageStream(in page: CGPDFPage, _ body: (CGPDFStreamRef) -> Void) {
    guard let dict = page.dictionary else { return }
    var resources: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else {
      return
    }
    visit(resources: resources, depth: 0, body)
  }

  private static func visit(
    resources: CGPDFDictionaryRef, depth: Int, _ body: (CGPDFStreamRef) -> Void
  ) {
    var xobjects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else {
      return
    }
    // `CGPDFDictionaryApplyBlock` kaçış yapan kapanış ister; akışları önce topla, sonra işle.
    var streams: [CGPDFStreamRef] = []
    CGPDFDictionaryApplyBlock(
      xobjects,
      { _, object, _ in
        var stream: CGPDFStreamRef?
        if CGPDFObjectGetValue(object, .stream, &stream), let stream { streams.append(stream) }
        return true
      }, nil)
    for stream in streams {
      guard let streamDict = CGPDFStreamGetDictionary(stream) else { continue }
      var subtype: UnsafePointer<Int8>?
      guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtype), let subtype else { continue }
      switch String(cString: subtype) {
      case "Image":
        body(stream)
      case "Form" where depth < maxFormDepth:
        var formResources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(streamDict, "Resources", &formResources),
          let formResources
        {
          visit(resources: formResources, depth: depth + 1, body)
        }
      default:
        continue
      }
    }
  }

  /// Bir sayfanın görüntü akışlarının SHA-256 (onaltılık) listesi, SIRALI — akışların sözlükteki
  /// sırası/adı (`/Im9` → `/Fx0` içinde `/Im9`) değişse de aynı görüntüler aynı listeyi verir.
  public static func imageHashes(of page: CGPDFPage) -> [String] {
    var hashes: [String] = []
    forEachImageStream(in: page) { stream in
      var format = CGPDFDataFormat.raw
      guard let data = CGPDFStreamCopyData(stream, &format) as Data? else {
        // Akış okunamadı: boş değil, AYIRT EDİLEBİLİR bir işaret — sessizce atlanırsa iki tarafta
        // da okunamayan görüntü "eşit" görünürdü ama sayılar yine de kıyaslanır.
        hashes.append("unreadable")
        return
      }
      let digest = SHA256.hash(data: data)
      hashes.append(digest.map { String(format: "%02x", $0) }.joined())
    }
    return hashes.sorted()
  }

  /// Belgenin her sayfası için `imageHashes` (indeks 0 = sayfa 1). Belge açılamazsa ya da bir
  /// sayfa okunamazsa `nil` — çağıran bunu "doğrulanamadı" sayar, "eşit" saymaz.
  public static func pageImageHashes(at url: URL) -> [[String]]? {
    guard let document = CGPDFDocument(url as CFURL), document.isUnlocked else { return nil }
    var result: [[String]] = []
    result.reserveCapacity(document.numberOfPages)
    for index in stride(from: 1, through: document.numberOfPages, by: 1) {
      guard let page = document.page(at: index) else { return nil }
      result.append(autoreleasepool { imageHashes(of: page) })
    }
    return result
  }

  /// Kaynak ve çıktı listelerinde görüntü kimliği FARKLI olan sayfalar (1 tabanlı). Sayfa sayıları
  /// farklıysa fazlalık sayfalar da farklı sayılır.
  public static func changedPages(source: [[String]], output: [[String]]) -> [Int] {
    let count = max(source.count, output.count)
    var changed: [Int] = []
    for index in 0..<count {
      let lhs = index < source.count ? source[index] : nil
      let rhs = index < output.count ? output[index] : nil
      if lhs != rhs { changed.append(index + 1) }
    }
    return changed
  }
}
