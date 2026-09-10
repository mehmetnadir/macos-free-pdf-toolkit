import Foundation

/// Kullanıcıya görünen metinlerin çevirisi.
///
/// TASARIM KARARI: anahtar, İNGİLİZCE KAYNAK METNİN KENDİSİDİR (`"Trim Bleed"` gibi), soyut bir
/// anahtar (`"op.trim.title"`) değil. Gerekçesi ölçüme dayanıyor: 917261e commit'inde çevrilen
/// 343 metnin 283'ü (%82) düz metin, yani 20 işlem dosyasının hiçbirine dokunmadan gösterim
/// anında çevrilebiliyor. Bunun iki ek kazancı var:
///   1. Çeviri bulunamazsa İngilizce metin AYNEN döner — arayüzde asla `op.trim.title` gibi
///      çıplak anahtar görünmez (soyut anahtar kullanan sistemlerin klasik arızası).
///   2. İngilizce metin kodda okunur kalır; kaynak ile çeviri arasında kayma olduğunda
///      `LocalizationTests` sözleşme testi bunu KIRMIZI verir (anahtar artık tabloda yok).
/// Bedeli: içine değer gömülü metinler (`"\(done) done"`) bu yolla çevrilemez; onlar açık
/// biçim anahtarlarıyla (`text(_:locale:_:)`) ele alınır.
public enum L10n {
  /// Desteklenen diller. Yeni dil eklemek: `<kod>.lproj/Localizable.strings` + buraya bir case.
  public enum Language: String, Sendable, CaseIterable {
    case english = "en"
    case turkish = "tr"

    /// Verilen locale'in karşılık düştüğü dil; tanınmayan diller İngilizce'ye düşer.
    public static func matching(_ locale: Locale) -> Language {
      let code = locale.language.languageCode?.identifier ?? "en"
      return Language(rawValue: code) ?? .english
    }
  }

  /// Çeviri tabloları dil başına BİR KEZ okunur. `.strings` diskten her çağrıda okunursa
  /// liste kaydırmada (her satır için birkaç metin) ölçülebilir gecikme olur.
  private static let cache = TableCache()

  /// Düz metin çevirisi. Çeviri yoksa `english` AYNEN döner.
  public static func tr(_ english: String, locale: Locale) -> String {
    guard case .turkish = Language.matching(locale) else { return english }
    return cache.table(for: .turkish)[english] ?? english
  }

  /// Biçimli metin: `english` bir biçim dizgesidir (`"%d of %d"`). Çeviri yoksa İngilizce
  /// biçim kullanılır — argümanlar her iki durumda da aynı sırada uygulanır.
  public static func text(_ english: String, locale: Locale, _ arguments: any CVarArg...) -> String {
    let format = tr(english, locale: locale)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: locale, arguments: arguments)
  }

  /// Bir dilin tablosundaki TÜM anahtarlar — sözleşme testleri için (eksik çeviri avı).
  public static func keys(for language: Language) -> Set<String> {
    Set(cache.table(for: language).keys)
  }

  /// Ek bir çeviri paketi kaydeder. GEREKÇE: her SwiftPM hedefinin kaynakları KENDİ
  /// `Bundle.module`unda durur; çekirdek, arayüzün (`PDFToolsApp`) tablosunu göremez. Arayüz
  /// açılışta kendi paketini kaydeder ve tablolar BİRLEŞTİRİLİR. Böylece çekirdek arayüz
  /// metinlerini taşımak zorunda kalmaz (katman karışmaz).
  /// Aynı anahtar iki pakette varsa SONRA kaydedilen kazanır (arayüz, çekirdeği ezebilir).
  public static func register(_ bundle: Bundle) {
    cache.register(bundle)
  }

  /// Tablo okuma tek yerde ve kilitli: `Sendable` bir sabit üzerinden paylaşıldığı için
  /// eşzamanlı çağrılarda sözlük yeniden kurulmasın.
  private final class TableCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [Language: [String: String]] = [:]
    private var bundles: [Bundle] = [.module]

    func register(_ bundle: Bundle) {
      lock.lock()
      defer { lock.unlock() }
      guard !bundles.contains(bundle) else { return }
      bundles.append(bundle)
      tables.removeAll()  // yeni paket geldi: önbellek geçersiz.
    }

    func table(for language: Language) -> [String: String] {
      lock.lock()
      defer { lock.unlock() }
      if let cached = tables[language] { return cached }
      var merged: [String: String] = [:]
      for bundle in bundles {
        merged.merge(Self.load(language, from: bundle)) { _, newer in newer }
      }
      tables[language] = merged
      return merged
    }

    /// `.strings` dosyası bir plist'tir; `PropertyListSerialization` ile okunur. Dosya yoksa
    /// (ör. henüz çevrilmemiş bir dil) BOŞ tablo döner — çağıran İngilizce'ye düşer, çökme yok.
    private static func load(_ language: Language, from bundle: Bundle) -> [String: String] {
      guard
        let url = bundle.url(
          forResource: "Localizable", withExtension: "strings",
          subdirectory: nil, localization: language.rawValue),
        let data = try? Data(contentsOf: url),
        let plist = try? PropertyListSerialization.propertyList(
          from: data, options: [], format: nil),
        let table = plist as? [String: String]
      else { return [:] }
      return table
    }
  }
}
