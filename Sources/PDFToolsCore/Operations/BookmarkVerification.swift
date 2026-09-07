import Foundation
import PDFKit

/// "Yer İmleri" işleminin JSON'daki sayının GERÇEK doküman anahattıyla (outline) uyuştuğunu ölçer —
/// pdfcpu'nun kendi bildirdiği sayıya güvenmez, PDFKit ile BAĞIMSIZ bir sayım yapılır (bkz.
/// `BookmarkOperation` dosya üstü yorumu).
public enum BookmarkVerification {
  /// `url`'deki PDF'in doküman anahattındaki (outline) TÜM düğümlerini (iç içe alt düğümler dahil)
  /// sayar. Anahat yoksa (`outlineRoot == nil`) 0.
  public static func outlineCount(_ url: URL) -> Int {
    guard let document = PDFDocument(url: url) else { return 0 }
    return count(document.outlineRoot)
  }

  private static func count(_ node: PDFOutline?) -> Int {
    guard let node else { return 0 }
    var total = 0
    for index in 0..<node.numberOfChildren {
      guard let child = node.child(at: index) else { continue }
      total += 1 + count(child)
    }
    return total
  }
}
