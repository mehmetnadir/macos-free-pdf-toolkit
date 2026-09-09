import AppKit
import PDFToolsCore
import SwiftUI

/// "Bu araç kurulu değil — şöyle kurulur — kurunca buraya dön" akışı.
///
/// Tasarım kararı: kullanıcıyı soluk bir kartla baş başa bırakmak yerine ne yapacağını
/// SÖYLÜYORUZ. Komut kopyalanabilir (elle yazdırmak hata kaynağı), Homebrew'u olmayan için
/// resmi indirme sayfası var, ve "Check Again" kurulumdan sonra uygulamayı yeniden başlatmayı
/// gereksiz kılıyor — kurulum bittiğinde kullanıcı zaten Terminal'dedir, geri dönüp tek düğmeye
/// basar (Nadir'in tarifi, 2026-09-09).
struct ToolSetupSheet: View {
  let requirement: ToolRequirement
  /// Aracın ŞU AN kurulu olup olmadığını yeniden ölçer — önbelleğe bakmaz.
  let recheck: () -> Bool
  let onClose: () -> Void

  @State private var checkResult: CheckResult?
  @State private var didCopy = false

  private enum CheckResult: Equatable {
    case found
    case stillMissing
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "shippingbox")
          .font(.system(size: 28, weight: .light))
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("\(requirement.name) is not installed").font(.title3.weight(.semibold))
          Text("Needed for \(requirement.purpose)")
            .font(.callout).foregroundStyle(.secondary)
        }
      }

      Text(requirement.whyNotBundled)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 6) {
        Text("Paste this into Terminal").font(.callout.weight(.medium))
        HStack(spacing: 8) {
          Text(requirement.installCommand)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
          Button(didCopy ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(requirement.installCommand, forType: .string)
            didCopy = true
          }
        }
        Link("No Homebrew? Download it here", destination: requirement.homepage)
          .font(.caption)
      }

      if let checkResult {
        switch checkResult {
        case .found:
          Label("\(requirement.name) found — you can run it now.", systemImage: "checkmark.circle")
            .foregroundStyle(.green).font(.callout)
        case .stillMissing:
          Label(
            "Still not found. Finish the install in Terminal, then check again.",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.orange).font(.callout)
        }
      }

      HStack {
        Button("Check Again") {
          checkResult = recheck() ? .found : .stillMissing
          if checkResult == .found { onClose() }
        }
        Spacer()
        Button("Close", action: onClose).keyboardShortcut(.cancelAction)
      }
    }
    .padding(22)
    .frame(width: 460)
  }
}
