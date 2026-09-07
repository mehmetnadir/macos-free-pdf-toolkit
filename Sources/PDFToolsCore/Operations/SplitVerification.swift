import CoreGraphics
import Foundation

/// "Parçala" çıktısının doğruluğunu ölçer: en az bir parça üretilmiş mi, hiçbir parça 0 sayfa
/// değil mi, parça sayfa sayılarının toplamı kaynağın sayfa sayısına eşit mi.
public enum SplitVerification {
  public static func verify(_ outputs: [URL], expectedTotal: Int) -> Bool {
    guard !outputs.isEmpty else { return false }
    var sum = 0
    for url in outputs {
      guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return false }
      sum += doc.numberOfPages
    }
    return sum == expectedTotal
  }
}
