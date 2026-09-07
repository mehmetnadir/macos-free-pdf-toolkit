import CoreGraphics
import Foundation
import ImageIO

/// "Görüntüye Aktar" çıktısının doğruluğunu ölçer: piksel boyutu beklenenle uyuşuyor mu, görüntü
/// gerçekten boş mu (tamamen beyaz sayfa üretme hatasını yakalamak için).
public enum ImageExportVerification {
  public struct Result: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Beyaz (luma ≥ 250) OLMAYAN piksellerin oranı, yüzde. 0 ise görüntü tamamen beyazdır.
    public let nonWhitePercent: Double
  }

  /// Bu luma değerinin (0–255, gri tonlama) altı "mürekkep var" sayılır; `TrimVerification`'la
  /// aynı eşik ailesinden, biraz daha toleranslı (JPEG sıkıştırma gürültüsünü hesaba katar).
  private static let inkLumaThreshold: UInt8 = 250

  /// `url`'deki görüntüyü okuyup piksel boyutunu ve beyaz-olmayan piksel oranını ölçer.
  /// Görüntü açılamıyorsa `nil` döner.
  public static func inspect(_ url: URL) -> Result? {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return Result(width: width, height: height, nonWhitePercent: 0) }
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return Result(width: width, height: height, nonWhitePercent: 0) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = ctx.data else { return Result(width: width, height: height, nonWhitePercent: 0) }
    let bytesPerRow = ctx.bytesPerRow
    let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    var nonWhite = 0
    for row in 0..<height {
      let rowStart = row * bytesPerRow
      for col in 0..<width where buffer[rowStart + col] < inkLumaThreshold { nonWhite += 1 }
    }
    let percent = Double(nonWhite) / Double(width * height) * 100
    return Result(width: width, height: height, nonWhitePercent: percent)
  }

  /// Beklenen piksel boyutu `dpi × sayfa punto / 72`'dir; `tolerancePx` kadar yuvarlama farkına izin verir.
  public static func matchesExpectedSize(
    _ result: Result, pagePoints: CGSize, dpi: CGFloat, tolerancePx: Int = 2
  ) -> Bool {
    let expectedWidth = Int((pagePoints.width * dpi / 72).rounded())
    let expectedHeight = Int((pagePoints.height * dpi / 72).rounded())
    return abs(result.width - expectedWidth) <= tolerancePx && abs(result.height - expectedHeight) <= tolerancePx
  }

  /// Görüntünün "boş değil" sayılması için gereken asgari beyaz-olmayan piksel oranı (yüzde).
  public static let minNonWhitePercentForNonEmpty: Double = 0.5
}
