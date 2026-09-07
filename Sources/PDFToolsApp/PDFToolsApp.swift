import AppKit
import PDFToolsCore
import SwiftUI

/// Finder "Birlikte Aç" / Dock'a bırakma ile gelen dosyalar. `.onOpenURL` KULLANILMAZ:
/// macOS'ta WindowGroup'a eklenince açılış penceresini bastırıyor (ölçüldü, 2026-09-07).
final class AppDelegate: NSObject, NSApplicationDelegate {
  var openHandler: (([URL]) -> Void)?
  private var pending: [URL] = []

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
}

@main
struct PDFToolsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .onAppear {
          // Odak ÇALINMAZ: `NSApp.activate(ignoringOtherApps: true)` kullanılmıyor.
          // Uygulamayı açan eylem (Finder'da çift tık, `open`) zaten öne getiriyor; bu çağrı
          // ise kullanıcı başka bir uygulamada çalışırken bile pencereyi zorla öne atıyordu
          // ve arka planda başlatmayı (`open -g`) imkânsız kılıyordu.
          let model = model
          appDelegate.attach { urls in Task { await model.add(urls: urls) } }
        }
    }
    .windowResizability(.contentMinSize)
    .defaultSize(width: 640, height: 460)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Dosya Ekle…") { model.pickFiles() }
          .keyboardShortcut("o", modifiers: .command)
        Button("Listeyi Temizle") { model.clear() }
          .keyboardShortcut(.delete, modifiers: [.command, .shift])
          .disabled(model.items.isEmpty || model.isRunning)
      }
    }
  }
}
