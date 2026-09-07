import PDFToolsCore
import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @State private var isDropTargeted = false

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      // Ön analiz satırı: dosya yoksa hiç görünmez (bkz. `AppModel.analysisSummary`).
      if let summary = model.analysisSummary {
        Text(summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
        Divider()
      }

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
      // Eylem kartları: uygulanabilirliğe dayalı seçim (İşlem Picker'ının yerini alır, bkz.
      // `.claude/CLAUDE.md` Tur 3). Seçili kartın seçenekleri (varsa) hemen altında.
      ActionCardsView()
      OperationOptionsRow()
      Divider()
      ActionBar()
    }
    .frame(minWidth: 640, minHeight: 480)
    .dropDestination(for: URL.self) { urls, _ in
      Task { await model.add(urls: urls) }
      return true
    } isTargeted: { isDropTargeted = $0 }
    .sheet(isPresented: $model.isShowingPageGridEditor) {
      if let target = model.pageGridTargetItem {
        PageGridView(
          fileInfo: target.info, cache: model.thumbnailCache,
          onApply: { pageOrder, rotations in
            model.isShowingPageGridEditor = false
            model.applyPageEdit(targetID: target.id, pageOrder: pageOrder, rotations: rotations)
          },
          onCancel: { model.isShowingPageGridEditor = false }
        )
      }
    }
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
      capabilitiesList
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

  /// Boş ekranda altı yeteneğin adı — okunur ama soluk (bkz. görev tanımı, Tur 3): henüz dosya
  /// yokken "bu araç ne yapabilir" sorusuna kısayol.
  private var capabilitiesList: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 8)], spacing: 8
    ) {
      ForEach(OperationRegistry.all, id: \.id) { op in
        Label(op.title, systemImage: op.systemImage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .opacity(0.6)
    .frame(maxWidth: 460)
    .padding(.top, 14)
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
      FileThumbnailView(url: item.info.url, cache: model.thumbnailCache)
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

/// Dosya listesindeki satırın küçük resmi: PDF'in İLK sayfası, `PageThumbnailCache` üzerinden.
/// Gelene kadar genel Finder ikonu kalır (`ASLA boş beyaz kutu` kuralı) — yükleme `.task` ile
/// arka planda olur, ana thread'i bloklamaz.
struct FileThumbnailView: View {
  let url: URL
  let cache: PageThumbnailCache
  @State private var thumbnail: NSImage?

  var body: some View {
    Group {
      if let thumbnail {
        Image(nsImage: thumbnail).resizable()
      } else {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
      }
    }
    .frame(width: 32, height: 32)
    .task(id: url) {
      guard let cgImage = await cache.thumbnail(for: url, page: 1, maxPixel: 64) else { return }
      let size = NSSize(width: cgImage.width, height: cgImage.height)
      thumbnail = NSImage(cgImage: cgImage, size: size)
    }
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

// MARK: - Eylem kartları

/// İşlem Picker'ının yerini alan ızgara: her kart bir `PDFOperation` — ikon, başlık, tek satır alt
/// metin. Uygulanamayan kartlar GİZLENMEZ, SOLDURULUR (keşfedilebilirlik) ve tıklanamaz olur; kart
/// seçimi = işlem seçimi (bkz. `AppModel.selectOperation`).
struct ActionCardsView: View {
  @Environment(AppModel.self) private var model

  private let columns = [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 8)]

  var body: some View {
    let files = model.items.map(\.info)
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(OperationRegistry.all, id: \.id) { op in
        let applicability = op.applicability(for: files)
        ActionCardView(
          operation: op,
          subtitle: cardSubtitle(for: op, applicability: applicability),
          isApplicable: isApplicable(applicability),
          isSelected: model.selectedOperationID == op.id,
          isDisabled: model.isRunning,
          onSelect: { model.selectOperation(op.id) }
        )
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 6)
  }

  private func isApplicable(_ applicability: OperationApplicability) -> Bool {
    if case .applicable = applicability { return true }
    return false
  }

  /// Kart alt metni: uygulanabilirse varsayılan "N dosyada", bazı işlemler bunun yerine kendi
  /// cümlesini gösterir (Birleştir, Sayfa Düzenle — bkz. görev tanımı, Tur 3); değilse gerekçe.
  private func cardSubtitle(for operation: any PDFOperation, applicability: OperationApplicability)
    -> String
  {
    switch applicability {
    case .notApplicable(let reason):
      return reason
    case .applicable(let count):
      switch operation.id {
      case MergeOperation.identifier:
        return "\(count) dosyayı birleştirir"
      case PageEditOperation.identifier:
        return "Sayfa düzenleme tek dosyada çalışır — ilk dosya kullanılacak"
      default:
        return "\(count) dosyada"
      }
    }
  }
}

struct ActionCardView: View {
  let operation: any PDFOperation
  let subtitle: String
  let isApplicable: Bool
  let isSelected: Bool
  let isDisabled: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 8) {
        Image(systemName: operation.systemImage)
          .font(.title3)
          .frame(width: 20)
          .foregroundStyle(isSelected ? Color.accentColor : .primary)
        VStack(alignment: .leading, spacing: 1) {
          Text(operation.title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
      )
    }
    .buttonStyle(.plain)
    .opacity(isApplicable ? 1 : 0.45)
    .disabled(!isApplicable || isDisabled)
    .help(subtitle)
  }
}

// MARK: - Seçenekler satırı

/// Seçili kartın seçenekleri (Parçala kipi, Görüntü biçimi/çözünürlüğü) + şifre alanı (Kilit Aç) —
/// eylem kartlarının HEMEN altında, ince bir satır. Hiçbiri gerekmiyorsa satır hiç görünmez.
struct OperationOptionsRow: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    let options = model.operation.options
    if model.needsPassword || !options.isEmpty {
      HStack(spacing: 12) {
        if model.needsPassword {
          SecureField("Şifre", text: $model.password)
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .disabled(model.isRunning)
        }
        ForEach(options) { option in
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
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 8)
    }
  }
}

// MARK: - Alt çubuk

struct ActionBar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 12) {
      statusView
      Spacer()
      if model.isRunning {
        Button("Durdur") { model.cancel() }
          .keyboardShortcut(.cancelAction)
      } else {
        Button(model.operation.actionTitle) { runOrOpenPageGrid() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canRun)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
  }

  /// Solda tek durum metni: özet (bitti/hata sayısı) → motor uyarısı → inceleniyor. Dosya sayısı
  /// ayrıca burada YAZILMAZ — ön analiz satırı zaten gösteriyor (bkz. `AppModel.analysisSummary`).
  @ViewBuilder
  private var statusView: some View {
    if let summary = model.summary {
      Text(summary).font(.callout).foregroundStyle(.secondary)
    } else if !model.hasRequiredEngine {
      Label(model.missingEngineMessage, systemImage: "exclamationmark.triangle")
        .font(.callout).foregroundStyle(.orange)
    } else if model.isInspecting {
      ProgressView().controlSize(.small)
    }
  }

  /// Sayfa Düzenle işleminde "Sayfaları Uygula" pipeline'ı HEMEN başlatmaz — önce ızgara sheet'i
  /// açılır (bkz. `AppModel.beginPageEdit`); diğer işlemler her zamanki gibi `run()` ile çalışır.
  private func runOrOpenPageGrid() {
    if model.selectedOperationID == PageEditOperation.identifier {
      model.beginPageEdit()
    } else {
      model.run()
    }
  }
}
