import CoreGraphics
import Foundation

/// Bir PDF'in kilit durumu. CGPDFDocument ile sayfa ayrıştırmadan, anında tespit edilir.
public enum PDFLockState: Sendable, Equatable {
  /// Şifreleme yok.
  case none
  /// Yalnızca sahip (owner) şifresi var: şifresiz açılır ama izinler kısıtlı.
  case restricted
  /// Açmak için kullanıcı şifresi gerekiyor.
  case passwordRequired
  /// Geçerli bir PDF değil ya da okunamadı.
  case unreadable

  public var label: String {
    switch self {
    case .none: return "Kilitsiz"
    case .restricted: return "İzinler kısıtlı"
    case .passwordRequired: return "Şifre gerekli"
    case .unreadable: return "Okunamıyor"
    }
  }
}

public struct PDFFileInfo: Sendable, Equatable, Hashable {
  public let url: URL
  public let fileSize: Int64
  public let pageCount: Int
  public let lockState: PDFLockState
  /// İlk sayfanın MediaBox'ı (sayfa geometrisinin tamamı). Okunamadıysa `.zero`.
  public let mediaBox: CGRect
  /// İlk sayfanın TrimBox'ı — yalnızca MediaBox'tan anlamlı ölçüde (≥ 0,5 punto, bkz.
  /// `boxToleranceMin`) farklıysa dolu. Eşitse (ya da hiç tanımlı değilse, ki bu durumda
  /// `CGPDFPageGetBoxRect` PDF spesifikasyonundaki miras kuralıyla MediaBox'a düşer) `nil`.
  public let trimBox: CGRect?
  /// `trimBox != nil` ile aynı; "bu dosyada atılacak bir kesim payı var mı" sorusuna kısa yol.
  public let hasBleed: Bool

  public init(
    url: URL, fileSize: Int64, pageCount: Int, lockState: PDFLockState,
    mediaBox: CGRect = .zero, trimBox: CGRect? = nil
  ) {
    self.url = url
    self.fileSize = fileSize
    self.pageCount = pageCount
    self.lockState = lockState
    self.mediaBox = mediaBox
    self.trimBox = trimBox
    self.hasBleed = trimBox != nil
  }

  public var fileName: String { url.lastPathComponent }

  /// Kesim payının (bleed) en geniş kenarı, punto cinsinden — `trimBox == nil` ise `nil`.
  /// Ön analiz satırında ("N dosyada X mm kesim payı") temsili değer olarak kullanılır.
  public var bleedInsetPoints: CGFloat? {
    guard let trim = trimBox else { return nil }
    return max(
      trim.minX - mediaBox.minX, trim.minY - mediaBox.minY,
      mediaBox.maxX - trim.maxX, mediaBox.maxY - trim.maxY)
  }

  /// İki kutunun her kenarda en az bu kadar (punto) farklı olması "anlamlı fark" sayılır.
  /// Altındaki farklar yuvarlama/floating-point gürültüsü kabul edilir.
  private static let boxToleranceMin: CGFloat = 0.5

  private static func boxesDiffer(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) >= boxToleranceMin || abs(a.minY - b.minY) >= boxToleranceMin
      || abs(a.maxX - b.maxX) >= boxToleranceMin || abs(a.maxY - b.maxY) >= boxToleranceMin
  }

  /// Dosyayı okuyup kilit durumunu ve sayfa sayısını çıkarır. Büyük dosyalarda bile hızlıdır
  /// (yalnızca xref/trailer okunur); yine de ana thread dışında çağrılması önerilir.
  public static func inspect(_ url: URL) -> PDFFileInfo {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    guard let document = CGPDFDocument(url as CFURL) else {
      return PDFFileInfo(url: url, fileSize: size, pageCount: 0, lockState: .unreadable)
    }
    let state: PDFLockState
    if !document.isEncrypted {
      state = .none
    } else if document.isUnlocked {
      state = .restricted
    } else {
      state = .passwordRequired
    }
    let pages = document.isUnlocked ? document.numberOfPages : 0
    var mediaBox = CGRect.zero
    var trimBox: CGRect?
    if document.isUnlocked, let page = document.page(at: 1) {
      mediaBox = page.getBoxRect(.mediaBox)
      let rawTrimBox = page.getBoxRect(.trimBox)
      if boxesDiffer(rawTrimBox, mediaBox) {
        trimBox = rawTrimBox
      }
    }
    return PDFFileInfo(
      url: url, fileSize: size, pageCount: pages, lockState: state,
      mediaBox: mediaBox, trimBox: trimBox)
  }

  /// Belge genelinde TrimBox'ın sayfalar arası tutarlı olup olmadığını kontrol eder.
  /// Performans için yalnız ilk `sampleLimit` sayfa örneklenir — kesim payı tipik olarak bir
  /// belgenin tamamında aynıdır (tek bir baskı şablonundan üretilir), tüm sayfaları gezmek
  /// büyük dosyalarda (yüzlerce sayfa) gereksiz yavaşlık yaratır.
  public static func trimBoxIsConsistent(_ url: URL, sampleLimit: Int = 50) -> Bool {
    guard let document = CGPDFDocument(url as CFURL), document.isUnlocked else { return true }
    let count = document.numberOfPages
    guard count > 1, let firstPage = document.page(at: 1) else { return true }
    let reference = firstPage.getBoxRect(.trimBox)
    let limit = min(count, sampleLimit)
    guard limit > 1 else { return true }
    for index in 2...limit {
      guard let page = document.page(at: index) else { continue }
      if boxesDiffer(page.getBoxRect(.trimBox), reference) { return false }
    }
    return true
  }

  /// Bir URL listesini PDF dosyalarına açar: klasörler bir seviye taranır, PDF olmayanlar elenir.
  public static func collectPDFs(from urls: [URL]) -> [URL] {
    var result: [URL] = []
    let fm = FileManager.default
    for url in urls {
      var isDirectory: ObjCBool = false
      guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        let children = (try? fm.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        result += children
          .filter { $0.pathExtension.lowercased() == "pdf" }
          .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      } else if url.pathExtension.lowercased() == "pdf" {
        result.append(url)
      }
    }
    return result
  }
}
