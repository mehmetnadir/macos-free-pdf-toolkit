import Combine
import Sparkle

/// Sparkle'ın standart güncelleyicisini SwiftUI menü katmanına köprüleyen sarmalayıcı.
/// `SPUStandardUpdaterController` kendi güncelleme UI'ını (alert/sheet) Sparkle içinden
/// yönetir; burada yalnızca menüden tetikleme ve tercih (otomatik kontrol) yüzeyini
/// SwiftUI'ye gözlenebilir şekilde açıyoruz. Yalnız PDFToolsApp içinde kullanılır —
/// PDFToolsCore ve pdftools bu tipten habersizdir.
@MainActor
final class UpdaterController: ObservableObject {
  let controller: SPUStandardUpdaterController

  /// Menüdeki "Check for Updates…" öğesinin etkin/pasif durumu — bir kontrol sürerken
  /// veya kullanıcı izinleri buna izin vermezken Sparkle bunu `false` yapar. Sparkle'ın
  /// kendi KVO'sundan Combine publisher'ı ile beslenir, elle tetiklenmez.
  @Published private(set) var canCheckForUpdates = false

  init() {
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    controller.updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)
  }

  /// Kullanıcı tetiklemeli güncelleme kontrolü (menüden "Check for Updates…").
  func checkForUpdates() {
    controller.updater.checkForUpdates()
  }

  /// Otomatik arka plan kontrolü tercihi. Sparkle bu değeri kendi user defaults
  /// anahtarında (`SUEnableAutomaticChecks`) saklar — burada yalnızca köprüleniyor.
  /// Kullanıcı bunu menüden KAPATABİLİR (README: işlem sırasında ağ çağrısı yok kuralı,
  /// otomatik kontrol bir ağ çağrısıdır).
  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }
}
