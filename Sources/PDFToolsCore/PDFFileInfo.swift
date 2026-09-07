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

  public init(url: URL, fileSize: Int64, pageCount: Int, lockState: PDFLockState) {
    self.url = url
    self.fileSize = fileSize
    self.pageCount = pageCount
    self.lockState = lockState
  }

  public var fileName: String { url.lastPathComponent }

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
    return PDFFileInfo(url: url, fileSize: size, pageCount: pages, lockState: state)
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
