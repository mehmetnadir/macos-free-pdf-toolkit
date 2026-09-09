import CoreGraphics
import Foundation

/// Sayfalardaki açıklama (`/Annots`) sayısı: bağlantılar, form alanları, notlar.
///
/// Neden var: `CoreGraphicsTrimEngine` sayfayı yeniden çizerek kestiği için açıklamaları
/// KORUYAMIYOR — ölçüldü (2026-09-09, 12 sayfalık gerçek dosya, 24 açıklamanın 24'ü kayboldu;
/// aynı dosya Ghostscript ile kesildiğinde 24'ü de korunuyor). Bu, kullanıcının fark
/// edemeyeceği türden bir kayıp: dosya açılır, sayfalar yerindedir, yalnız bağlantılar
/// çalışmaz. Bu yüzden kesmeden ÖNCE sayılır ve motor ona göre seçilir.
public enum PDFAnnotations {
  /// Belgedeki toplam açıklama sayısı. Dosya açılamazsa 0.
  public static func count(in url: URL) -> Int {
    guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return 0 }
    var total = 0
    for index in 1...document.numberOfPages {
      guard let page = document.page(at: index), let dictionary = page.dictionary else { continue }
      var annotations: CGPDFArrayRef?
      if CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations {
        total += CGPDFArrayGetCount(annotations)
      }
    }
    return total
  }
}
