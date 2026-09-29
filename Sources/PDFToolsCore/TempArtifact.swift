import Darwin
import Foundation

/// GÜVENLİ ara/geçici dosya üretimi — bu deponun TEK ortak yardımcısı.
///
/// TEHDİT (2026-09-29 güvenlik denetimi). Depo genelinde onlarca çağrı noktası hedef dizinde
/// ÖNGÖRÜLEBİLİR gizli adlarla (`.<ad>.part.pdf`, `.<ad>.repair.pdf`, `.<ad>.qpdf-update.json` vb.)
/// ara dosya oluşturuyordu: `try? fm.removeItem(at: partial)` ile "varsa sil", sonra qpdf/
/// Ghostscript/CGContext doğrudan o yola yazıyordu — `O_EXCL` yok, `O_NOFOLLOW` yok, sembolik bağ
/// koruması yok. Kullanıcının çıktı klasörü paylaşımlıysa (SMB, Dropbox/iCloud, `/Users/Shared`,
/// çok kullanıcılı Mac) aynı makinedeki başka bir yerel kullanıcı bu adı ÖNCEDEN sembolik bağ
/// olarak oluşturabilir: `UnlockOperation` özelinde qpdf şifresi çözülmüş PDF'i bağlantının
/// hedefine yazar (veri sızıntısı), diğer işlemlerde rastgele bir dosya ezilir (veri kaybı).
///
/// İKİ YÖNTEM, iki farklı "kim yazıyor" sınıfı için — ikisi de adı ÖNGÖRÜLEMEZ (UUID) yapar,
/// öngörülemezliğin ÜSTÜNE bir de sistem çağrısı düzeyinde koruma ekler:
///
/// 1. `reserveExclusiveFile`/`writeExclusive` — Swift'in KENDİSİ veri yazdığı durumlar (JSON/Data/
///    metin). Dosya `open(2)` ile `O_EXCL | O_NOFOLLOW | O_CREAT` bayraklarıyla PEŞİNEN açılır:
///    `O_CREAT | O_EXCL` dosya zaten VARSA (sembolik bağın hedefi dahil) `open`'ı `EEXIST` ile
///    BAŞARISIZ kılar; `O_NOFOLLOW` son bileşen bir sembolik bağSA `open`'ı `ELOOP` ile başarısız
///    kılar. Yani bir saldırgan tam bu adı ÖNCEDEN (dosya ya da sembolik bağ olarak) oluşturmuş
///    olsa bile açma adımı reddedilir — veri sembolik bağın hedefine ASLA akmaz. İzinler baştan
///    `0600` verilir (`open` bayrağıyla, sonradan `chmod` YOK — aradaki pencerede başka bir
///    kullanıcı dosyayı okuyamaz).
///
/// 2. `withPrivateDirectory`/`withPrivateDirectorySync` — hedef dosyayı bir ALT SÜREÇ (qpdf,
///    Ghostscript) ya da bir Apple çerçevesi (`CGDataConsumer(url:)`, `CGImageDestinationCreateWithURL`)
///    KENDİSİ oluşturduğu durumlar. Bu araçlara açık bir dosya tanıtıcısı veremeyiz — bazı
///    araçlar (qpdf) zaten var olan bir tanıtıcıya değil, kendi açtığı bir yola yazmayı bekler.
///    Bunun yerine `mkdir(2)` ile TEK kullanıcıya ait (`0700`), benzersiz (UUID) adlı bir alt dizin
///    açılır. `mkdir` var olan bir yolun (sembolik bağ dahil) ÜZERİNE GEÇMEZ, `EEXIST` ile
///    başarısız olur — ad zaten benzersiz olduğundan bu ikinci bir güvenlik katmanı. Alt süreç
///    kendi dosyasını bu dizinin İÇİNE, sabit/basit bir adla yazar; dizin sahipliği tek kullanıcı
///    OLDUĞU için içeride artık sembolik bağ yarışı yoktur (saldırganın önceden bu dizinin içine
///    bir şey koyması mümkün değildir — dizin bu çağrıdan önce YOKTU).
///
/// Her iki yöntem de `defer` ile İŞ BİTİNCE (başarı ya da hata FARK ETMEKSİZİN) temizlik yapar —
/// hata yollarında geçici dosya/dizin asla kalmaz.
public enum TempArtifact {
  public enum ArtifactError: Error, LocalizedError, Equatable {
    /// `open(O_EXCL|O_NOFOLLOW|O_CREAT)` başarısız oldu — `errno` genelde `EEXIST` (dosya/sembolik
    /// bağ zaten var) ya da `ELOOP` (son bileşen sembolik bağ).
    case exclusiveCreateFailed(path: String, errno: Int32)
    /// `mkdir(0700)` başarısız oldu — `errno` genelde `EEXIST`.
    case directoryCreateFailed(path: String, errno: Int32)

    public var errorDescription: String? {
      switch self {
      case .exclusiveCreateFailed(let path, let code):
        return
          "Could not exclusively create a temporary file at \(path) "
          + "(errno \(code): \(String(cString: strerror(code))))"
      case .directoryCreateFailed(let path, let code):
        return
          "Could not create a private temporary directory at \(path) "
          + "(errno \(code): \(String(cString: strerror(code))))"
      }
    }
  }

  // MARK: - 1) Swift'in kendisi yazdığı durumlar

  /// `directory` içinde `.<UUID><suffix>` adlı bir dosyayı `O_EXCL | O_NOFOLLOW | O_CREAT` ile
  /// açar, izinleri baştan `0600`. Döndürülen `FileHandle` ÇAĞIRANINDIR — yazıp KAPATMASI gerekir;
  /// kapatılmadan atılırsa tanıtıcı `FileHandle`'ın `deinit`'i ile kapanır ama hatanın erken
  /// yakalanması için çağıranın açıkça `close()` çağırması ve `try`/`catch` içinde tutması önerilir.
  public static func reserveExclusiveFile(
    in directory: URL, suffix: String
  ) throws -> (url: URL, handle: FileHandle) {
    let url = directory.appendingPathComponent(".\(UUID().uuidString)\(suffix)")
    let fd = url.path.withCString { path in
      open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    }
    guard fd >= 0 else {
      throw ArtifactError.exclusiveCreateFailed(path: url.path, errno: errno)
    }
    return (url, FileHandle(fileDescriptor: fd, closeOnDealloc: true))
  }

  /// `data`'yı `directory` içinde benzersiz, `O_EXCL`-korumalı TEK bir dosyaya yazar ve URL'sini
  /// döner. Çoğu çağıran dosyayı açıp tek seferde yazıp kapatıyor — bu kısayol o deseni kapsar.
  @discardableResult
  public static func writeExclusive(_ data: Data, in directory: URL, suffix: String) throws -> URL {
    let (url, handle) = try reserveExclusiveFile(in: directory, suffix: suffix)
    do {
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    return url
  }

  // MARK: - 2) Alt süreç / Apple çerçevesinin dosyayı KENDİSİ oluşturduğu durumlar

  /// `directory` içinde benzersiz (UUID adlı), `0700` izinli bir alt dizin `mkdir` ile açar,
  /// `perform`'a verir; `perform` bitince (başarı ya da hata FARK ETMEKSİZİN, `defer`) dizini
  /// İÇERİĞİYLE BİRLİKTE siler.
  public static func withPrivateDirectory<T>(
    in directory: URL, perform: (URL) async throws -> T
  ) async throws -> T {
    let dir = try makePrivateDirectory(in: directory)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await perform(dir)
  }

  /// `withPrivateDirectory`'nin eşzamanlı (subprocess/async GEREKTİRMEYEN, salt CoreGraphics
  /// çağıranlar için) eşdeğeri — `async` bağlamı olmayan çağrı noktalarında (`BlankPDF`) kullanılır.
  public static func withPrivateDirectorySync<T>(
    in directory: URL, perform: (URL) throws -> T
  ) throws -> T {
    let dir = try makePrivateDirectory(in: directory)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try perform(dir)
  }

  private static func makePrivateDirectory(in directory: URL) throws -> URL {
    let dir = directory.appendingPathComponent(".pdftools-\(UUID().uuidString)", isDirectory: true)
    let created = dir.path.withCString { path in mkdir(path, 0o700) }
    guard created == 0 else {
      throw ArtifactError.directoryCreateFailed(path: dir.path, errno: errno)
    }
    return dir
  }

  // MARK: - 3) Paylaşılan/kalıcı bir dizin içinde, salt öngörülemezlik gereken dar durum

  /// `directory`'nin KENDİSİ paylaşılan/kalıcı bir konum olduğu (her defasında taze bir özel alt
  /// dizin AÇILAMADIĞI — ör. `PageThumbnailCache`'in dosya başına yeniden kullanılan disk
  /// önbelleği dizini) VE hedef dosyayı bir Apple çerçevesinin (`CGImageDestinationCreateWithURL`)
  /// KENDİSİ path'ten oluşturduğu dar durumlar için: yalnızca ÖNGÖRÜLEMEZ (UUID) bir ad üretir.
  /// `reserveExclusiveFile`/`withPrivateDirectory`'nin aksine `open`/`mkdir` düzeyinde EK bir
  /// sistem-çağrısı koruması YOKTUR (dosyayı biz açmıyoruz, açamayız) — kapattığı tek risk,
  /// saldırganın adı ÖNCEDEN TAHMİN edip bir sembolik bağ yerleştirebilmesidir; bu üç yöntemin
  /// EN ZAYIFI, yalnızca diğer ikisinin uygulanamadığı yerde kullanılır. Çağıran kendi silme
  /// sorumluluğunu taşır (bu fonksiyon `defer` içermez, çünkü hiçbir kaynak açılmıyor).
  public static func unpredictablePath(in directory: URL, suffix: String) -> URL {
    directory.appendingPathComponent(".\(UUID().uuidString)\(suffix)")
  }
}
