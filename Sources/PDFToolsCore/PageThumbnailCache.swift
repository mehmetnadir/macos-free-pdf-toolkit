import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// PDF sayfa küçük resimleri için iki katmanlı (bellek + disk) kalıcı önbellek. Yüksek çözünürlüklü
/// (100–600 MB) ders kitabı PDF'lerinde her küçük resmi ham dosyadan yeniden render etmek çok yavaş
/// olduğu için var; sonuçlar hem `NSCache` (RAM) hem de `~/Library/Caches/<bundle-id>/thumbs/`
/// (disk, HEIC/JPEG/PNG) altında saklanır. Arayüzsüz bir katmandır — kullanıcıya görünen metin yok.
///
/// Tasarım kararları (hepsi ölçülmüş/kanıtlı gerekçelere dayanıyor):
/// - Anahtar dosya yolu + boyut + mtime + sayfa no + maxPixel'in SHA-256 özetidir: kaynak dosya
///   değişince anahtar da değişir, bayat küçük resim asla dönmez.
/// - Disk biçimi ÇALIŞMA ANINDA seçilir (`CGImageDestinationCopyTypeIdentifiers()`): HEIC varsa HEIC
///   (aynı sayfa için PNG 8,7 MB / JPEG 4,2 MB / HEIC 1,8 MB ölçüldü — 6 sayfa toplamı), yoksa JPEG,
///   o da yoksa PNG. `ImageExportOperation.heicWriteSupported` ile AYNI teknik, kod tekrarı burada
///   bilinçli: bu dosya başka bir kaynağa dokunmadan tek başına derlenip test edilebilmeli.
/// - Her render kendi `CGContext`'ini açar — paylaşılan/mutable bir context'i eşzamanlı render'lar
///   arasında yeniden kullanmak Apple geliştirici forumlarında bildirilen bir çökme sebebi.
/// - Aynı (dosya, sayfa, boyut) için eşzamanlı istekler TEK render'a düşer (in-flight tablo); ikinci
///   ve sonraki istekler birincinin sonucunu bekler, ayrı bir render tetiklemez.
public actor PageThumbnailCache {

  // MARK: - Genel API

  public struct Stats: Sendable, Equatable {
    public let hits: Int
    public let misses: Int
    public let diskBytes: Int64
  }

  /// Bellek bütçesi: fiziksel bellek YÜZDESİ değil, sabit 256 MB — büyük/küçük Mac'lerde öngörülebilir
  /// davranış için (görev tanımında bilerek "sınır ~%25 fiziksel bellek DEĞİL" diye belirtildi).
  private static let memoryBudgetBytes = 256 * 1024 * 1024
  /// Disk bütçesi: aşılınca en eski erişilenden (LRU) budanır, budama render yolunu bloklamaz.
  private static let diskBudgetBytes: Int64 = 1_073_741_824

  private let memoryCache = NSCache<NSString, CGImage>()
  private let diskDirectory: URL?

  private var hits = 0
  private var misses = 0
  private var inFlight: [String: Task<Lookup?, Never>] = [:]
  /// dosya-anahtarı → o dosyaya ait bellekteki varyant anahtarları. Yalnızca `clear(for:)`'ın hangi
  /// `NSCache` girdilerini sileceğini bilmesi için tutulur (`NSCache` enumerasyon sunmuyor).
  private var fileIndex: [String: Set<NSString>] = [:]

  /// - Parameter cacheDirectory: Verilmezse gerçek uygulama önbellek klasörü kullanılır
  ///   (`~/Library/Caches/<bundle-id>/thumbs`). Testlerde izole bir geçici klasör vermek için var.
  public init(cacheDirectory: URL? = nil) {
    memoryCache.totalCostLimit = Self.memoryBudgetBytes
    let resolved = cacheDirectory ?? Self.defaultCacheDirectory()
    // Dizin oluşturulamıyorsa (izin/disk sorunu) sessizce bellek-içi çalışmaya devam et — dayanıklılık
    // kuralı: bozuk/eksik önbellek çökmeye değil, güvenli bir düşüşe (fallback) yol açmalı.
    if let resolved, (try? FileManager.default.createDirectory(
      at: resolved, withIntermediateDirectories: true)) != nil {
      diskDirectory = resolved
    } else {
      diskDirectory = nil
    }
  }

  private static func defaultCacheDirectory() -> URL? {
    guard let base = try? FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    let bundleID = Bundle.main.bundleIdentifier ?? "com.ydspublishing.pdftools"
    return base.appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("thumbs", isDirectory: true)
  }

  /// `url`'deki PDF'in `page` (1-tabanlı) sayfasının küçük resmini döner. Önce bellek, sonra disk
  /// önbelleğine bakılır; ikisi de ıskalarsa render edilip her iki katmana da yazılır. Aynı anahtar
  /// için eşzamanlı çağrılar tek render'a düşer (in-flight birleştirme).
  public func thumbnail(for url: URL, page: Int, maxPixel: Int) async -> CGImage? {
    guard maxPixel > 0, page >= 1 else { return nil }
    guard let (size, mtime) = Self.fileStat(url) else { return nil }
    let path = url.standardizedFileURL.path
    let fileKey = Self.hash(path)
    let variantKey = Self.hash("\(path)|\(size)|\(mtime.timeIntervalSince1970)|\(page)|\(maxPixel)")

    if let cached = memoryCache.object(forKey: variantKey as NSString) {
      hits += 1
      return cached
    }
    if let existing = inFlight[variantKey] {
      hits += 1
      return (await existing.value)?.image
    }

    let diskDir = diskDirectory
    let task = Task.detached(priority: .userInitiated) { () -> Lookup? in
      if let diskImage = Self.loadFromDisk(key: variantKey, fileKey: fileKey, diskDirectory: diskDir) {
        return .diskHit(diskImage)
      }
      guard let rendered = Self.renderThumbnail(url: url, page: page, maxPixel: maxPixel) else {
        return nil
      }
      return .rendered(rendered)
    }
    inFlight[variantKey] = task

    let outcome = await task.value
    guard let outcome else {
      inFlight[variantKey] = nil
      return nil
    }
    switch outcome {
    case .diskHit(let image):
      hits += 1
      storeInMemory(image, key: variantKey, fileKey: fileKey)
    case .rendered(let image):
      misses += 1
      storeInMemory(image, key: variantKey, fileKey: fileKey)
      // Disk yazımı ACTOR'IN DIŞINDA (detached) yapılır ama bu çağrı SONUCU dönmeden önce
      // TAMAMLANMASI beklenir — `statistics()`/sonraki bir çağrı hemen ardından disk girdisini
      // güvenilir şekilde görebilmeli (aksi halde disk yazımı bir yarış durumuna dönüşür).
      // `await` actor'ı BLOKLAMAZ (bu noktada yield eder, başka çağrılar ilerleyebilir) — bloklanan
      // yalnızca BU isteğin kendi dönüşüdür. Budama ise bilerek fire-and-forget: 1 GB'a yaklaşan bir
      // önbellekte dizin taraması pahalı olabilir, o YÜZDEN render/dönüş yolunu bloklamaz (kural #7).
      await Task.detached(priority: .utility) {
        Self.saveToDisk(image, key: variantKey, fileKey: fileKey, diskDirectory: diskDir)
      }.value
      Task.detached(priority: .background) {
        Self.pruneDiskIfNeeded(diskDirectory: diskDir)
      }
    }
    inFlight[variantKey] = nil
    return outcome.image
  }

  /// Verilen sayfa aralığını (1-tabanlı, üst sınır hariç) düşük öncelikli arka planda üretir; çağıran
  /// beklemez (fonksiyon `async` değil, hemen döner). Eşzamanlı render sayısı fiziksel/etkin çekirdek
  /// sayısıyla sınırlıdır — tüm aralığı aynı anda ateşlemek büyük dosyalarda CPU'yu boğar.
  public nonisolated func prefetch(for url: URL, pages: Range<Int>, maxPixel: Int) {
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      await self.runPrefetch(url: url, pages: pages, maxPixel: maxPixel)
    }
  }

  private func runPrefetch(url: URL, pages: Range<Int>, maxPixel: Int) async {
    let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)
    var iterator = pages.makeIterator()
    await withTaskGroup(of: Void.self) { group in
      func addNext() {
        guard let page = iterator.next() else { return }
        guard page >= 1 else { return }
        group.addTask { [weak self] in
          guard let self else { return }
          _ = await self.thumbnail(for: url, page: page, maxPixel: maxPixel)
        }
      }
      for _ in 0..<limit { addNext() }
      while await group.next() != nil {
        addNext()
      }
    }
  }

  /// Bellek + disk sayaçlarını okur. `diskBytes` disk önbelleğinin GERÇEK anlık boyutudur (canlı
  /// tarama), ayrı bir sayaçla senkron tutmaya çalışmak sürüklenme (drift) riski taşır.
  public func statistics() -> Stats {
    Stats(hits: hits, misses: misses, diskBytes: Self.diskUsage(diskDirectory))
  }

  /// `url` verilirse yalnız o dosyaya ait tüm varyantları (her sayfa/boyut) siler; `nil` ise önbelleğin
  /// tamamını (bellek + disk) temizler. Sayaçlar (`hits`/`misses`) dokunulmadan kalır — bunlar ömür
  /// boyu performans göstergesi, önbellek İÇERİĞİNİN durumu değil.
  public func clear(for url: URL?) {
    guard let url else {
      memoryCache.removeAllObjects()
      fileIndex.removeAll()
      inFlight.removeAll()
      if let diskDirectory {
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
      }
      return
    }
    let fileKey = Self.hash(url.standardizedFileURL.path)
    for variant in fileIndex[fileKey] ?? [] {
      memoryCache.removeObject(forKey: variant)
    }
    fileIndex[fileKey] = nil
    if let diskDirectory {
      try? FileManager.default.removeItem(
        at: diskDirectory.appendingPathComponent(fileKey, isDirectory: true))
    }
  }

  // MARK: - Actor-izole yardımcılar (paylaşılan mutable duruma dokunur)

  private func storeInMemory(_ image: CGImage, key: String, fileKey: String) {
    // Maliyet = piksel baytı (RGB + dolgu, 4 bayt/piksel) — görev tanımındaki "maliyet = piksel
    // baytı" kuralı; NSCache bu maliyeti totalCostLimit'e göre tahliye kararında kullanır.
    let cost = image.width * image.height * 4
    memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    fileIndex[fileKey, default: []].insert(key as NSString)
  }

  // MARK: - nonisolated saf I/O (actor'ı I/O/CPU süresince MEŞGUL ETMEMEK için ayrı tutulur)

  private enum Lookup: @unchecked Sendable {
    case diskHit(CGImage)
    case rendered(CGImage)

    var image: CGImage {
      switch self {
      case .diskHit(let image), .rendered(let image): return image
      }
    }
  }

  private enum DiskFormat: Sendable {
    case heic, jpeg, png

    var uti: CFString {
      switch self {
      case .heic: return "public.heic" as CFString
      case .jpeg: return "public.jpeg" as CFString
      case .png: return "public.png" as CFString
      }
    }

    var fileExtension: String {
      switch self {
      case .heic: return "heic"
      case .jpeg: return "jpg"
      case .png: return "png"
      }
    }
  }

  /// Bu sistemde YAZILABİLEN en iyi biçim — ÇALIŞMA ANINDA ölçülür, sabit varsayılmaz (bkz. dosya üstü
  /// yorum). `ImageExportOperation.heicWriteSupported` ile aynı teknik, bilinçli kod tekrarı.
  private nonisolated static func resolveDiskFormat() -> DiskFormat {
    guard let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] else { return .png }
    if identifiers.contains("public.heic") { return .heic }
    if identifiers.contains("public.jpeg") { return .jpeg }
    return .png
  }

  private nonisolated static func hash(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// KASITLI olarak `URL.resourceValues(forKeys:)` DEĞİL, `FileManager.attributesOfItem(atPath:)`
  /// kullanılıyor: `URL` değeri kendi içinde resource value'ları ÖNBELLEKLER — aynı `URL` (veya ondan
  /// türeyen bir kopya) tekrar tekrar sorgulandığında dosya gerçekte değişmiş olsa bile ESKİ
  /// boyut/mtime döner (bu proje içinde ölçülüp doğrulandı: dosya değişince önbellek geçersiz kalma
  /// testi `resourceValues` ile SESSİZCE yanlış geçiyordu — bayat anahtar üretip eski küçük resmi
  /// haklı çıkarıyordu). `attributesOfItem` her çağrıda taze bir `stat()` yapar, önbellek YOK.
  private nonisolated static func fileStat(_ url: URL) -> (size: Int64, mtime: Date)? {
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let sizeNumber = attrs[.size] as? NSNumber,
      let mtime = attrs[.modificationDate] as? Date
    else { return nil }
    return (sizeNumber.int64Value, mtime)
  }

  /// PDF sayfasını render eder. `CGPDFDocument`/`CGPDFPage`/`CGContext` bu çağrı boyunca yaşar ve
  /// hiçbir actor durumuna dokunmaz — her çağrı kendi belgesini kendi açar (paylaşılan mutable
  /// context YOK, bkz. dosya üstü yorum).
  private nonisolated static func renderThumbnail(url: URL, page: Int, maxPixel: Int) -> CGImage? {
    guard let document = CGPDFDocument(url as CFURL), document.isUnlocked else { return nil }
    guard page <= document.numberOfPages, let pdfPage = document.page(at: page) else { return nil }

    let box = pdfPage.getBoxRect(.cropBox)
    guard box.width > 0, box.height > 0 else { return nil }

    // Sayfa döndürmesini (/Rotate) dikkate al: 90/270 derecede görünen (visual) en-boy, kutunun
    // kendi en-boyundan farklıdır — hedef piksel boyutunu buna göre hesapla.
    let rotation = pdfPage.rotationAngle
    let rotated = rotation == 90 || rotation == 270
    let visualWidth = rotated ? box.height : box.width
    let visualHeight = rotated ? box.width : box.height
    guard visualWidth > 0, visualHeight > 0 else { return nil }

    let scale = CGFloat(maxPixel) / max(visualWidth, visualHeight)
    let pxWidth = max(1, Int((visualWidth * scale).rounded()))
    let pxHeight = max(1, Int((visualHeight * scale).rounded()))

    guard
      let ctx = CGContext(
        data: nil, width: pxWidth, height: pxHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    // Beyaz zemine çiz (şeffaf DEĞİL) — kesim payı/görüntü aktarma doğrulayıcılarıyla aynı kural.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))

    // CGPDFPageGetDrawingTransform CropBox'ı VE sayfanın kendi /Rotate açısını hedef dikdörtgene göre
    // otomatik hizalar/döndürür/ölçekler (Apple'ın kendi algoritması) — rotasyonu elle hesaplamaya
    // gerek yok; `ctx.drawPDFPage` bu transform concatenate edilmeden çağrılırsa /Rotate'i YOK SAYAR.
    let destRect = CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight)
    let transform = pdfPage.getDrawingTransform(
      .cropBox, rect: destRect, rotate: 0, preserveAspectRatio: true)
    ctx.concatenate(transform)
    ctx.drawPDFPage(pdfPage)

    return ctx.makeImage()
  }

  /// `<diskDirectory>/<fileKey>/<variantKey>.<uzantı>` yolunda önbelleğe alınmış bir küçük resim
  /// arar. Bozuk/eksik dosya bulunursa sessizce siler ve `nil` döner (dayanıklılık kuralı: çökme YOK,
  /// render yoluna düş).
  private nonisolated static func loadFromDisk(
    key: String, fileKey: String, diskDirectory: URL?
  ) -> CGImage? {
    guard let diskDirectory else { return nil }
    let dir = diskDirectory.appendingPathComponent(fileKey, isDirectory: true)
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
      return nil
    }
    guard let match = entries.first(where: { $0.deletingPathExtension().lastPathComponent == key })
    else { return nil }
    guard
      let source = CGImageSourceCreateWithURL(match as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      try? fm.removeItem(at: match)
      return nil
    }
    // LRU: bu dosya az önce kullanıldı, "son erişim" için mtime'ı şimdiye çek. APFS'te dosya erişim
    // tarihi (atime) varsayılan olarak güncellenmediğinden mtime erişim vekili olarak kullanılıyor —
    // budama bu alana göre en eskiyi seçiyor (bkz. `pruneDiskIfNeeded`).
    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: match.path)
    return image
  }

  /// Yeni render edilen küçük resmi diske yazar: önce gizli `.part` dosyasına, biçim TAMAMLANINCA
  /// (`CGImageDestinationFinalize`) asıl ada taşınır — yarım kalmış bir yazım asla "geçerli" dosya
  /// gibi görünmez (Operations katmanındaki `.part` deseniyle aynı mantık).
  private nonisolated static func saveToDisk(
    _ image: CGImage, key: String, fileKey: String, diskDirectory: URL?
  ) {
    guard let diskDirectory else { return }
    let fm = FileManager.default
    let dir = diskDirectory.appendingPathComponent(fileKey, isDirectory: true)
    guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return }

    let format = resolveDiskFormat()
    let finalURL = dir.appendingPathComponent(key).appendingPathExtension(format.fileExtension)
    let tempURL = dir.appendingPathComponent(".\(key).part.\(format.fileExtension)")
    try? fm.removeItem(at: tempURL)

    guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, format.uti, 1, nil)
    else { return }
    var properties: [CFString: Any] = [:]
    if format != .png {
      properties[kCGImageDestinationLossyCompressionQuality] = 0.82
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? fm.removeItem(at: tempURL)
      return
    }
    try? fm.removeItem(at: finalURL)
    try? fm.moveItem(at: tempURL, to: finalURL)
  }

  /// Disk kullanımı 1 GB bütçeyi aşıyorsa en eski erişilenden (mtime) başlayarak buda. Her zaman
  /// `Task.detached` içinden, actor'ın DIŞINDA çağrılır — büyük bir önbellekte dizin taraması actor'ı
  /// meşgul edip diğer `thumbnail(for:page:maxPixel:)` çağrılarını bloklamamalı.
  private nonisolated static func pruneDiskIfNeeded(diskDirectory: URL?) {
    guard let diskDirectory else { return }
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: diskDirectory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
    else { return }

    var entries: [(url: URL, size: Int64, mtime: Date)] = []
    var total: Int64 = 0
    for case let itemURL as URL in enumerator {
      guard
        let values = try? itemURL.resourceValues(
          forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
        values.isRegularFile == true
      else { continue }
      let size = Int64(values.fileSize ?? 0)
      total += size
      entries.append((itemURL, size, values.contentModificationDate ?? .distantPast))
    }
    guard total > diskBudgetBytes else { return }

    var remaining = total
    for entry in entries.sorted(by: { $0.mtime < $1.mtime }) {
      guard remaining > diskBudgetBytes else { break }
      try? fm.removeItem(at: entry.url)
      remaining -= entry.size
    }
  }

  private nonisolated static func diskUsage(_ diskDirectory: URL?) -> Int64 {
    guard let diskDirectory else { return 0 }
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: diskDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let itemURL as URL in enumerator {
      guard
        let values = try? itemURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true
      else { continue }
      total += Int64(values.fileSize ?? 0)
    }
    return total
  }
}
