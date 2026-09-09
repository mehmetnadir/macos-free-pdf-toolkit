import Foundation

/// Toplu koşunun genel ilerleme kesrini hesaplar.
///
/// Arayüzden (AppModel) ayrı tutuluyor çünkü `PDFToolsApp` çalıştırılabilir bir hedef ve test
/// edilemiyor; ilerleme yanlış hesaplanırsa kullanıcı "%80"de duran bir çubuğa bakar ve buna
/// kimse hata demez — sessiz bozulma. Bu yüzden matematik burada, testli.
public enum BatchProgressMath {
  /// - Parameters:
  ///   - completed: bitmiş (done/skipped/failed) dosya sayısı.
  ///   - inFlight: o an çalışan dosyaların kesirleri (bilinmiyorsa 0 geçilir).
  ///   - total: bu koşudaki toplam dosya sayısı.
  /// - Returns: 0...1 arası kesir. `total <= 0` ise 0.
  ///
  /// `.combined` (Birleştir) kipinde TÜM dosyalar aynı anda aynı kesirle çalışır: toplam N,
  /// `inFlight` toplamı ≈ N × f, `completed` 0 → sonuç ≈ f. Yani aynı formül iki kip için de
  /// doğru; ayrı dal gerekmiyor.
  public static func fraction(completed: Int, inFlight: [Double], total: Int) -> Double {
    guard total > 0 else { return 0 }
    let running = inFlight.reduce(0) { $0 + max(0, min(1, $1)) }
    let value = (Double(completed) + running) / Double(total)
    return min(1, max(0, value))
  }
}
