import PDFToolsCore
import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @State private var isDropTargeted = false

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      Group {
        if model.items.isEmpty {
          DropZoneView(isTargeted: isDropTargeted) { model.pickFiles() }
        } else {
          FileListView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        if isDropTargeted && !model.items.isEmpty {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .padding(6)
            .allowsHitTesting(false)
        }
      }

      Divider()
      ActionBar()
    }
    .frame(minWidth: 560, minHeight: 380)
    .dropDestination(for: URL.self) { urls, _ in
      Task { await model.add(urls: urls) }
      return true
    } isTargeted: { isDropTargeted = $0 }
    .navigationTitle("PDF Araçları")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button { model.pickFiles() } label: { Label("Ekle", systemImage: "plus") }
          .help("PDF ekle (⌘O)")
          .disabled(model.isRunning)
        Button { model.clear() } label: { Label("Temizle", systemImage: "trash") }
          .help("Listeyi temizle")
          .disabled(model.items.isEmpty || model.isRunning)
      }
    }
  }
}

// MARK: - Boş durum

struct DropZoneView: View {
  let isTargeted: Bool
  let onPick: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "arrow.down.doc")
        .font(.system(size: 52, weight: .light))
        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
      Text("PDF dosyalarını buraya sürükle")
        .font(.title3.weight(.medium))
      Text("Tek dosya, birden çok dosya ya da klasör")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button("Dosya Seç…", action: onPick)
        .controlSize(.large)
        .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(
          isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
          style: StrokeStyle(lineWidth: isTargeted ? 3 : 1.5, dash: [8, 6])
        )
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .padding(16)
    }
    .animation(.easeInOut(duration: 0.15), value: isTargeted)
  }
}

// MARK: - Dosya listesi

struct FileListView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      ForEach(model.items) { item in
        FileRowView(item: item)
          .contextMenu {
            Button("Finder'da Göster") { model.reveal(item.info.url) }
            if case .done(let urls, _) = item.status, let first = urls.first {
              Button(urls.count > 1 ? "Çıktıları Finder'da Göster" : "Çıktıyı Finder'da Göster") {
                model.reveal(first)
              }
            }
            Divider()
            Button("Listeden Kaldır", role: .destructive) { model.remove(item.id) }
              .disabled(model.isRunning)
          }
      }
      .onDelete { offsets in
        for index in offsets { model.remove(model.items[index].id) }
      }
    }
    .listStyle(.inset)
    .alternatingRowBackgrounds()
  }
}

struct FileRowView: View {
  let item: AppModel.FileItem
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: item.info.url.path))
        .resizable()
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.info.fileName)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(detailLine)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      StatusView(
        status: item.status,
        pendingSymbol: pendingSymbol,
        pendingHelp: isTrim ? bleedLabel : item.info.lockState.label,
        pendingIsProblem: item.info.lockState == .unreadable
      ) { url in model.reveal(url) }
    }
    .padding(.vertical, 3)
  }

  private var isTrim: Bool { model.selectedOperationID == TrimOperation.identifier }

  private var detailLine: String {
    var parts = [ByteCountFormatter.string(fromByteCount: item.info.fileSize, countStyle: .file)]
    if item.info.pageCount > 0 { parts.append("\(item.info.pageCount) sayfa") }
    // Seçili işlem neyse onun karar verdiği bilgiyi göster: kilit açmada kilit durumu,
    // kesimde kesim payı. Kullanıcı listeye bakıp işlemin ne yapacağını görebilmeli.
    parts.append(isTrim ? bleedLabel : item.info.lockState.label)
    return parts.joined(separator: " · ")
  }

  private var pendingSymbol: String {
    if item.info.lockState == .unreadable { return "xmark.octagon" }
    if isTrim { return item.info.trimBox == nil ? "rectangle.dashed" : "crop" }
    switch item.info.lockState {
    case .none: return "lock.open"
    case .restricted: return "lock.shield"
    case .passwordRequired: return "lock.fill"
    case .unreadable: return "xmark.octagon"
    }
  }

  /// Kesim payı özeti: kesilmiş ölçü + kenar payı, milimetre cinsinden.
  private var bleedLabel: String {
    guard let trim = item.info.trimBox else { return "Kesim payı yok" }
    let media = item.info.mediaBox
    let inset = max(
      trim.minX - media.minX, trim.minY - media.minY,
      media.maxX - trim.maxX, media.maxY - trim.maxY)
    // Ondalık ayırıcı sistem diline uymalı: Türkçede "3,0 mm", "3.0 mm" değil.
    func mm(_ points: CGFloat, decimals: Int) -> String {
      let value = Double(points) / 72 * 25.4
      return value.formatted(.number.precision(.fractionLength(decimals)))
    }
    return "\(mm(trim.width, decimals: 0)) × \(mm(trim.height, decimals: 0)) mm"
      + " · \(mm(inset, decimals: 1)) mm kesim payı"
  }
}

struct StatusView: View {
  let status: AppModel.ItemStatus
  let pendingSymbol: String
  let pendingHelp: String
  let pendingIsProblem: Bool
  let reveal: (URL) -> Void

  var body: some View {
    switch status {
    case .pending:
      Image(systemName: pendingSymbol)
        .foregroundStyle(pendingIsProblem ? Color.red : Color.secondary)
        .help(pendingHelp)
    case .running(let fraction):
      HStack(spacing: 8) {
        if let fraction {
          ProgressView(value: fraction).frame(width: 90)
          Text("%\(Int(fraction * 100))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.small)
        }
      }
    case .done(let urls, let note):
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        if let note {
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
        // Tek çıktı → "Göster"; birden çok → "N dosya · Göster" (Finder'da ilk dosya seçilir).
        Button(urls.count > 1 ? "\(urls.count) dosya · Göster" : "Göster") {
          if let first = urls.first { reveal(first) }
        }
        .buttonStyle(.link)
        .font(.caption)
        .help(urls.first?.lastPathComponent ?? "")
      }
    case .skipped(let reason):
      HStack(spacing: 6) {
        Image(systemName: "minus.circle").foregroundStyle(.secondary)
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
    case .failed(let message):
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .help(message)
    }
  }

}

// MARK: - Alt çubuk

struct ActionBar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    HStack(spacing: 12) {
      Picker("İşlem", selection: $model.selectedOperationID) {
        ForEach(OperationRegistry.all, id: \.id) { op in
          Label(op.title, systemImage: op.systemImage).tag(op.id)
        }
      }
      .fixedSize()
      .disabled(model.isRunning)

      if model.needsPassword {
        SecureField("Şifre", text: $model.password)
          .textFieldStyle(.roundedBorder)
          .frame(width: 150)
          .disabled(model.isRunning)
      }

      // İşlem seçenekleri (Parçala kipi, Görüntü biçimi/çözünürlüğü) — genel bir form motoru
      // yerine küçük Picker'lar; seçenek yoksa hiçbir şey görünmez.
      ForEach(model.operation.options) { option in
        Picker(option.label, selection: model.optionBinding(for: option)) {
          ForEach(option.choices, id: \.value) { choice in
            Text(choice.label).tag(choice.value)
          }
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(model.isRunning)
      }

      Spacer()

      if let summary = model.summary {
        Text(summary).font(.callout).foregroundStyle(.secondary)
      } else if !model.hasRequiredEngine {
        Label(model.missingEngineMessage, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.orange)
      } else if model.isInspecting {
        ProgressView().controlSize(.small)
      } else if !model.items.isEmpty {
        Text("\(model.items.count) dosya").font(.callout).foregroundStyle(.secondary)
      }

      if model.isRunning {
        Button("Durdur") { model.cancel() }
          .keyboardShortcut(.cancelAction)
      } else {
        Button(model.operation.actionTitle) { model.run() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canRun)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
  }
}
