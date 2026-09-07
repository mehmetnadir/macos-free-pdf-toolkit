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
            if case .done(let url) = item.status {
              Button("Çıktıyı Finder'da Göster") { model.reveal(url) }
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
      StatusView(status: item.status, lockState: item.info.lockState) { url in model.reveal(url) }
    }
    .padding(.vertical, 3)
  }

  private var detailLine: String {
    var parts = [ByteCountFormatter.string(fromByteCount: item.info.fileSize, countStyle: .file)]
    if item.info.pageCount > 0 { parts.append("\(item.info.pageCount) sayfa") }
    parts.append(item.info.lockState.label)
    return parts.joined(separator: " · ")
  }
}

struct StatusView: View {
  let status: AppModel.ItemStatus
  let lockState: PDFLockState
  let reveal: (URL) -> Void

  var body: some View {
    switch status {
    case .pending:
      Image(systemName: lockSymbol)
        .foregroundStyle(lockState == .unreadable ? Color.red : Color.secondary)
        .help(lockState.label)
    case .running(let fraction):
      HStack(spacing: 8) {
        if let fraction {
          ProgressView(value: fraction).frame(width: 90)
          Text("%\(Int(fraction * 100))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.small)
        }
      }
    case .done(let url):
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Button("Göster") { reveal(url) }
          .buttonStyle(.link)
          .font(.caption)
          .help(url.lastPathComponent)
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

  private var lockSymbol: String {
    switch lockState {
    case .none: return "lock.open"
    case .restricted: return "lock.shield"
    case .passwordRequired: return "lock.fill"
    case .unreadable: return "xmark.octagon"
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

      Spacer()

      if let summary = model.summary {
        Text(summary).font(.callout).foregroundStyle(.secondary)
      } else if !model.hasEngine {
        Label("PDF motoru bulunamadı", systemImage: "exclamationmark.triangle")
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
