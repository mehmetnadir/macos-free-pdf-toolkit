import Foundation
import PDFToolsCore
import SwiftUI

/// Arayüz dili. Metinler `L10n.tr(_:locale:)` ile GÖSTERİM ANINDA çözülür (bkz.
/// PDFToolsCore/Localization.swift): anahtar İngilizce metnin kendisi olduğu için çevirisi
/// olmayan bir metin İngilizce görünür, asla çıplak anahtar görünmez.
///
/// Neden SwiftUI'nin kendi `Text("...")` yerelleştirmesine GÜVENMİYORUZ: SwiftUI arama için
/// `Bundle.main`i kullanır, SwiftPM kaynakları ise ayrı bir `.bundle` içinde durur; ayrıca
/// `.environment(\.locale)`in dizge ARAMASINI etkileyip etkilemediği macOS sürümüne göre
/// değişebiliyor. Açık çözüm ölçülebilir ve sürümden bağımsız — bu projede tercih edilen yol.
enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case english
  case turkish

  var id: String { rawValue }

  /// Menüde görünen ad. Diller KENDİ dillerinde yazılır (Apple'ın dil listelerindeki kural):
  /// Türkçe bilmeyen biri "Türkçe"yi, İngilizce bilmeyen "English"i tanır.
  var menuTitle: String {
    switch self {
    case .system: return "System"
    case .english: return "English"
    case .turkish: return "Türkçe"
    }
  }

  /// Metin çözümünde kullanılacak locale. `.system` → macOS'un tercih ettiği dil.
  var locale: Locale {
    switch self {
    case .system: return Locale.autoupdatingCurrent
    case .english: return Locale(identifier: "en")
    case .turkish: return Locale(identifier: "tr")
    }
  }
}

/// Seçimi saklar ve arayüze dağıtır. `@AppStorage` yerine açık `UserDefaults`: aynı anahtarı
/// hem menü hem kök görünüm okuyor ve testte/ölçümde `defaults write` ile dışarıdan
/// ayarlanabilmesi gerekiyor.
@MainActor
final class LanguageSetting: ObservableObject {
  static let defaultsKey = "appLanguage"

  /// TEK örnek. Gerekçe (ölçülmüş arıza, 2026-09-10): uygulamanın İKİ pencere yolu var —
  /// olağan `WindowGroup` ve açılış yarışına karşı kurulan kurtarma penceresi
  /// (bkz. `AppDelegate.presentRescueWindow`). Dil ayarı yalnız birinciye bağlandığında,
  /// kurtarma penceresi açıldığında arayüz seçilen dili DEĞİL sistem dilini gösteriyordu ve
  /// bu sessiz kalıyordu (sistem dili Türkçe olduğu için "Türkçe çalışıyor" sanılıyordu).
  /// Tek kaynak: her iki yol da buradan okur.
  static let shared = LanguageSetting()

  @Published var language: AppLanguage {
    didSet {
      guard language != oldValue else { return }
      UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
    }
  }

  init(defaults: UserDefaults = .standard) {
    let stored = defaults.string(forKey: Self.defaultsKey) ?? AppLanguage.system.rawValue
    language = AppLanguage(rawValue: stored) ?? .system
  }
}
