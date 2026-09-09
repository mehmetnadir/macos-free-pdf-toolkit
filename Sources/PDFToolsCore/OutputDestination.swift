import Foundation

/// Çıktıların NEREYE yazılacağının sonucu. `OutputPlacement.resolve` üretir; `AppModel` hem
/// `OperationContext.outputDirectory` olarak işleme geçirir hem de `note`'u kullanıcıya gösterir.
public struct OutputDestination: Sendable, Equatable {
  public let directory: URL
  /// Toplu klasör açıldıysa adı (ör. "PDF Tools — Compress"); tek çıktıda `nil`.
  public let batchFolderName: String?
  /// Kaynak klasör yazılabilir olmadığı için Masaüstü'ne düşüldüyse `true`.
  public let usedFallback: Bool
  /// Kullanıcıya gösterilecek tek cümle; olağan durumda `nil` (sessiz kal, gürültü yapma).
  public let note: String?

  public init(directory: URL, batchFolderName: String?, usedFallback: Bool, note: String?) {
    self.directory = directory
    self.batchFolderName = batchFolderName
    self.usedFallback = usedFallback
    self.note = note
  }
}

public enum OutputPlacement {
  /// Çıktı klasörünü seçer.
  ///
  /// Kurallar (Nadir, 2026-09-09):
  /// - Çıktı TEK ise orijinalin yanına yazılır, ayrı klasör AÇILMAZ.
  /// - Çıktı BİRDEN ÇOK ise orijinalin yanında "PDF Tools — <İşlem>" klasörü açılır. Bu sayım
  ///   üst-düzey çıktı sayısıdır: Parçala tek dosya için tek bir `_parts/` klasörü ürettiğinden
  ///   ONA sarmalayıcı bir klasör daha açılmaz; üç dosya için üç `_parts/` üretileceğinden
  ///   açılır. Yani "işlem zaten klasör üretiyorsa sarmalama" kuralı sayımdan kendiliğinden çıkar.
  /// - Kaynak klasör yazılabilir değilse (salt-okunur birim, indirilenler karantinası) Masaüstü'ne
  ///   düşülür ve bu SÖYLENİR — sessizce başka yere yazmak kullanıcıyı dosyasını ararken bırakır.
  ///
  /// Toplu klasör GERÇEKTEN oluşturulur (işlemler var olmayan bir klasöre yazamaz). Hiç çıktı
  /// üretilmezse boş kalmasın diye `discardIfEmpty` ile geri alınır.
  public static func resolve(
    inputs: [URL],
    operationTitle: String,
    expectedTopLevelOutputs: Int,
    fileManager: FileManager = .default,
    fallbackDirectory: URL? = nil
  ) -> OutputDestination {
    let fallback =
      fallbackDirectory
      ?? fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory

    guard let first = inputs.first else {
      return OutputDestination(
        directory: fallback, batchFolderName: nil, usedFallback: true,
        note: "No source folder — saved to \(fallback.lastPathComponent)")
    }

    var base = first.deletingLastPathComponent()
    var usedFallback = false
    var note: String?
    if !fileManager.isWritableFile(atPath: base.path) {
      base = fallback
      usedFallback = true
      note = "The original folder is read-only — saved to \(fallback.lastPathComponent) instead"
    }

    guard expectedTopLevelOutputs > 1 else {
      return OutputDestination(
        directory: base, batchFolderName: nil, usedFallback: usedFallback, note: note)
    }

    let folderName = uniqueFolderName(in: base, preferred: "PDF Tools — \(operationTitle)",
                                      fileManager: fileManager)
    let folder = base.appendingPathComponent(folderName, isDirectory: true)
    do {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      // Klasör açılamadıysa çıktıyı kaybetmektense doğrudan taban klasöre yaz.
      return OutputDestination(
        directory: base, batchFolderName: nil, usedFallback: usedFallback, note: note)
    }
    return OutputDestination(
      directory: folder, batchFolderName: folderName, usedFallback: usedFallback, note: note)
  }

  /// Bu koşuda AÇILAN toplu klasör boş kaldıysa (hiçbir çıktı üretilmedi) geri alır. Yalnızca
  /// `batchFolderName` dolu VE klasör tamamen boşsa siler — kullanıcının verisine dokunmaz.
  @discardableResult
  public static func discardIfEmpty(
    _ destination: OutputDestination, fileManager: FileManager = .default
  ) -> Bool {
    guard destination.batchFolderName != nil else { return false }
    let contents = try? fileManager.contentsOfDirectory(atPath: destination.directory.path)
    guard let contents, contents.isEmpty else { return false }
    return (try? fileManager.removeItem(at: destination.directory)) != nil
  }

  private static func uniqueFolderName(
    in base: URL, preferred: String, fileManager: FileManager
  ) -> String {
    var name = preferred
    var counter = 2
    while fileManager.fileExists(atPath: base.appendingPathComponent(name).path) {
      name = "\(preferred) \(counter)"
      counter += 1
    }
    return name
  }
}
