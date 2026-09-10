import AppKit
import PDFToolsCore
import SwiftUI

/// Finder "Birlikte Aç" / Dock'a bırakma ile gelen dosyalar. `.onOpenURL` KULLANILMAZ:
/// macOS'ta WindowGroup'a eklenince açılış penceresini bastırıyor (ölçüldü, 2026-09-07).
///
/// Model BURADA yaşıyor (App'te `@State` değil). Sebep: aşağıdaki kurtarma penceresi,
/// SwiftUI hiç pencere kurmadığı için `ContentView.onAppear`'ın ÇALIŞMADIĞI durumda
/// devreye giriyor — o an modeli App'ten almanın bir yolu yok, delegate'in kendi elinde
/// olmak zorunda.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  var openHandler: (([URL]) -> Void)?
  private var pending: [URL] = []
  private var rescueWindow: NSWindow?

  func application(_ application: NSApplication, open urls: [URL]) {
    if let openHandler { openHandler(urls) } else { pending += urls }
  }

  func attach(_ handler: @escaping ([URL]) -> Void) {
    openHandler = handler
    if !pending.isEmpty {
      handler(pending)
      pending.removeAll()
    }
  }

  /// Uygulamanın kullanıcıya görünen bir penceresi var mı? `NSApp.windows` menü çubuğu
  /// öğeleri, paneller ve gizli yardımcı pencereleri de içerdiği için sayı YETMEZ —
  /// yalnız görünür VE ana olabilen pencere gerçek bir içerik penceresidir.
  static func needsRescueWindow(_ windows: [NSWindow]) -> Bool {
    !windows.contains { $0.isVisible && $0.canBecomeMain }
  }

  /// AÇILIŞ YARIŞI GÜVENLİK AĞI (ölçüldü 2026-09-09, log kanıtı).
  ///
  /// AppKit açılışta `_reopenWindowsAsNecessaryIncludingRestorableState` ile pencere
  /// geri yüklemeye çalışıyor (`hasPersistentStateToRestore=1`, kalıcı "NSWindow Frame …"
  /// kaydı yüzünden). Başarılı açılışlarda SwiftUI'nin `AppWindowsController` restorer'ı
  /// cevap verip pencereyi kuruyor; başarısız açılışlarda bu zincir HİÇ tetiklenmiyor ve
  /// `WindowGroup`'un varsayılan pencere açma yedeği OLMADIĞI için uygulama süresiz olarak
  /// penceresiz kalıyor (süreç ayakta, çökme yok, olay döngüsünde boşta — teşhis edilmesi
  /// en zor arıza türü: sessiz).
  ///
  /// Yarış yük altında ortaya çıkıyor, her açılışta değil; bu yüzden "bende çalışıyor"
  /// demek yeterli değil, yedek şart. Ağ YALNIZ gerçekten pencere yoksa kuruluyor,
  /// yani olağan açılışta ikinci pencere üretmez.
  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let self, Self.needsRescueWindow(NSApp.windows) else { return }
      self.presentRescueWindow()
    }
  }

  private func presentRescueWindow() {
    // Dil ortamı BURADA DA verilmek zorunda: eksik olduğunda bu pencere seçilen dili değil
    // sistem dilini gösteriyordu (ölçüldü 2026-09-10 — sistem Türkçe olduğu için arıza
    // "Türkçe çalışıyor" gibi görünüp gizlenmişti).
    let hosting = NSHostingController(
      rootView: ContentView()
        .environment(model)
        .environment(\.locale, LanguageSetting.shared.language.locale))
    let window = NSWindow(contentViewController: hosting)
    window.title = "PDF Tools"
    window.setContentSize(NSSize(width: 640, height: 460))
    window.center()
    rescueWindow = window
    // Odak ÇALINMAZ: `orderFront` uygulamayı öne getirmez, yalnız pencereyi kurar.
    window.makeKeyAndOrderFront(nil)
    let model = model
    attach { urls in Task { await model.add(urls: urls) } }
  }
}

@main
struct PDFToolsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var updaterController = UpdaterController()
  @StateObject private var languageSetting = LanguageSetting.shared

  init() {
    // Arayüzün çeviri tablosu AYRI bir paketde: SwiftPM her hedefin kaynaklarını kendi
    // `Bundle.module`una koyuyor ve çekirdek onu göremiyor. Kaydedilmezse arayüz metinleri
    // İngilizce kalır (sessiz arıza) — `L10n.register` tabloları birleştirir.
    L10n.register(.module)
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(appDelegate.model)
        // Dil seçimi TEK yerden dağıtılır; her görünüm `@Environment(\.locale)` okuyup
        // metnini `L10n.tr(_:locale:)` ile çözer (bkz. AppLanguage.swift gerekçesi).
        .environment(\.locale, languageSetting.language.locale)
        .onAppear {
          // Odak ÇALINMAZ: `NSApp.activate(ignoringOtherApps: true)` kullanılmıyor.
          // Uygulamayı açan eylem (Finder'da çift tık, `open`) zaten öne getiriyor; bu çağrı
          // ise kullanıcı başka bir uygulamada çalışırken bile pencereyi zorla öne atıyordu
          // ve arka planda başlatmayı (`open -g`) imkânsız kılıyordu.
          let model = appDelegate.model
          appDelegate.attach { urls in Task { await model.add(urls: urls) } }
        }
    }
    .windowResizability(.contentMinSize)
    .defaultSize(width: 640, height: 460)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Blank PDF…") { appDelegate.model.isShowingBlankPDF = true }
          .keyboardShortcut("n", modifiers: .command)
        Button("Add Files…") { appDelegate.model.pickFiles() }
          .keyboardShortcut("o", modifiers: .command)
        Button("Clear List") { appDelegate.model.clear() }
          .keyboardShortcut(.delete, modifiers: [.command, .shift])
          .disabled(appDelegate.model.items.isEmpty || appDelegate.model.isRunning)
      }
      // Apple standardı: uygulama menüsünde, About'un altında (bkz. HIG).
      CommandGroup(after: .appInfo) {
        Picker("Language", selection: $languageSetting.language) {
          ForEach(AppLanguage.allCases) { language in
            Text(language.menuTitle).tag(language)
          }
        }
        Divider()
        Button("Check for Updates…") { updaterController.checkForUpdates() }
          .disabled(!updaterController.canCheckForUpdates)
        Toggle(
          "Automatically Check for Updates",
          isOn: Binding(
            get: { updaterController.automaticallyChecksForUpdates },
            set: { updaterController.automaticallyChecksForUpdates = $0 }
          )
        )
      }
    }
  }
}
