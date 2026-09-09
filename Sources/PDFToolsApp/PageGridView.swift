import AppKit
import CoreGraphics
import PDFToolsCore
import SwiftUI

/// "Sayfa Düzenle" sheet'i: bir PDF'in sayfalarını küçük resim ızgarasında gösterir; seçim,
/// sürükle-bırak ile yeniden sıralama, döndürme ve silme (geri alınabilir) sağlar. "Uygula"
/// basıldığında plan `pageOrder`/`rotations` dizelerine çevrilip `onApply` ile dışarı verilir —
/// gerçek qpdf çağrısını BU DOSYA yapmaz, `AppModel.applyPageEdit` normal işlem akışını kullanır.
struct PageGridView: View {
  let fileInfo: PDFFileInfo
  let cache: PageThumbnailCache
  let onApply: (_ pageOrder: String, _ rotations: String) -> Void
  let onCancel: () -> Void

  /// Bir sayfanın ızgaradaki durumu. `id` KAYNAK sayfa numarasıdır (1-tabanlı) — sabit kimlik,
  /// sıralama değişse de aynı kalır. Silinen sayfalar dizi İÇİNDE kalır (kaybolmaz), yalnız
  /// `isDeleted` işaretlenir; bu sayede "geri al" sıfır maliyetli bir toggle'dır.
  fileprivate struct Cell: Identifiable, Equatable {
    let id: Int
    /// Kaynaktaki MEVCUT `/Rotate` değeri — sheet açılırken bir kez okunur. Kullanıcı hiç
    /// dokunmazsa plana hiç girmez (dokunulmamış sayfa mevcut rotasyonunu qpdf'te zaten korur).
    var baseRotation: Int
    /// Kullanıcının eklediği 90°'lik adım sayısı, [0,3] aralığında tutulur. Küçük resim ZATEN
    /// `baseRotation`'ı yansıttığı için (bkz. `PageThumbnailCache.renderThumbnail`), ekranda
    /// yalnız bu FARK kadar döndürülür — çift döndürme uygulanmasın diye.
    var extraSteps = 0
    var isDeleted = false

    /// qpdf'e verilecek MUTLAK hedef derece (`PageEditOperation` mutlak derece bekliyor, bkz. tip
    /// yorumu — göreli `+derece` idempotent değil).
    var targetRotation: Int { ((baseRotation + extraSteps * 90) % 360 + 360) % 360 }
    var isRotated: Bool { targetRotation != baseRotation }
  }

  @State private var cells: [Cell] = []
  @State private var selection: Set<Int> = []
  @State private var anchorID: Int?
  @State private var dropTargetID: Int?

  private let thumbMaxPixel = 240
  private let cellWidth: CGFloat = 150
  private let cellHeight: CGFloat = 190
  private let prefetchRadius = 12

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth + 30), spacing: 16)],
          spacing: 20
        ) {
          ForEach(cells) { cell in
            PageCellView(
              cell: cell, url: fileInfo.url, cache: cache, maxPixel: thumbMaxPixel,
              width: cellWidth, height: cellHeight,
              isSelected: selection.contains(cell.id), isDropTarget: dropTargetID == cell.id,
              onTap: { handleTap(cell.id) }, onRestore: { restore(cell.id) }
            )
            .onAppear { prefetch(around: cell.id) }
            .draggable(String(cell.id))
            .dropDestination(for: String.self) { items, _ in
              handleDrop(items, targetID: cell.id)
              return true
            } isTargeted: { isTargeted in
              dropTargetID = isTargeted ? cell.id : nil
            }
          }
        }
        .padding(18)
      }
      Divider()
      footer
    }
    .frame(minWidth: 760, minHeight: 580)
    .onAppear(perform: setupIfNeeded)
  }

  // MARK: - Başlık

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Organize Pages").font(.headline)
        Text("\(fileInfo.fileName) · \(counted(cells.count, "page"))")
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Button { rotate(by: -1) } label: { Image(systemName: "rotate.left") }
        .help("Rotate selected pages left").disabled(selection.isEmpty)
      Button { rotate(by: 1) } label: { Image(systemName: "rotate.right") }
        .help("Rotate selected pages right").disabled(selection.isEmpty)
      Button(role: .destructive) { toggleDeleteSelected() } label: {
        Label(deleteButtonTitle, systemImage: "trash")
      }
      .help("Delete or restore selected pages")
      .disabled(selection.isEmpty)
      .keyboardShortcut(.delete, modifiers: [])
      Button("Select All") { selectAll() }
        .keyboardShortcut("a", modifiers: .command)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var deleteButtonTitle: String {
    let selected = cells.filter { selection.contains($0.id) }
    let allDeleted = !selected.isEmpty && selected.allSatisfy(\.isDeleted)
    return allDeleted ? "Undo" : "Delete"
  }

  // MARK: - Alt çubuk

  private var footer: some View {
    HStack(spacing: 12) {
      Text(summaryText).font(.callout).foregroundStyle(keptCount == 0 ? .red : .secondary)
      Spacer()
      Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
      Button("Apply", action: apply)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canApply)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var deletedCount: Int { cells.filter(\.isDeleted).count }
  private var rotatedCount: Int { cells.filter { !$0.isDeleted && $0.isRotated }.count }
  private var keptCount: Int { cells.count - deletedCount }
  private var canApply: Bool { keptCount > 0 }

  /// Türkçe iyelik eki sayının son hecesine göre değişir (3'ü, 2'si, 5'i…) — bunu HERHANGİ bir
  /// sayı için doğru üretmek ayrı bir dilbilgisi motoru gerektirir. Onun yerine ek gerektirmeyen,
  /// her sayı için KESİN doğru olan bu biçim kullanılıyor.
  private var summaryText: String {
    guard keptCount > 0 else { return "All pages cannot be deleted — at least 1 page must remain" }
    return "\(counted(cells.count, "page")) · \(deletedCount) to delete · \(rotatedCount) to rotate"
  }

  // MARK: - Kurulum

  private func setupIfNeeded() {
    guard cells.isEmpty, fileInfo.pageCount > 0 else { return }
    let document = CGPDFDocument(fileInfo.url as CFURL)
    cells = (1...fileInfo.pageCount).map { page in
      let degree = document?.page(at: page).map { normalizedDegree($0.rotationAngle) } ?? 0
      return Cell(id: page, baseRotation: degree)
    }
  }

  private func normalizedDegree(_ raw: Int32) -> Int { ((Int(raw) % 360) + 360) % 360 }

  // MARK: - Seçim

  private func handleTap(_ id: Int) {
    let flags = NSEvent.modifierFlags
    if flags.contains(.shift) {
      selectRange(to: id)
    } else if flags.contains(.command) {
      toggleSelection(id)
    } else {
      selection = [id]
      anchorID = id
    }
  }

  private func toggleSelection(_ id: Int) {
    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    anchorID = id
  }

  private func selectRange(to id: Int) {
    guard let anchor = anchorID, let a = cells.firstIndex(where: { $0.id == anchor }),
      let b = cells.firstIndex(where: { $0.id == id })
    else {
      selection = [id]
      anchorID = id
      return
    }
    let range = a <= b ? a...b : b...a
    selection = Set(cells[range].map(\.id))
  }

  private func selectAll() { selection = Set(cells.map(\.id)) }

  // MARK: - Döndür / Sil / Geri Al

  private func rotate(by steps: Int) {
    for index in cells.indices where selection.contains(cells[index].id) {
      cells[index].extraSteps = ((cells[index].extraSteps + steps) % 4 + 4) % 4
    }
  }

  private func toggleDeleteSelected() {
    guard !selection.isEmpty else { return }
    let selected = cells.filter { selection.contains($0.id) }
    let restoring = selected.allSatisfy(\.isDeleted)
    for index in cells.indices where selection.contains(cells[index].id) {
      cells[index].isDeleted = !restoring
    }
  }

  private func restore(_ id: Int) {
    guard let index = cells.firstIndex(where: { $0.id == id }) else { return }
    cells[index].isDeleted = false
  }

  // MARK: - Sürükle-bırak

  /// Sürüklenen TEK sayfayı, bırakıldığı hücrenin ÖNÜNE taşır. Çoklu seçim sürüklemesi (bir bloğu
  /// birlikte taşıma) bilerek desteklenmiyor — kapsam basitliği için tek-sayfa taşıma yeterli.
  private func handleDrop(_ items: [String], targetID: Int) {
    guard let raw = items.first, let draggedID = Int(raw), draggedID != targetID,
      let fromIndex = cells.firstIndex(where: { $0.id == draggedID })
    else { return }
    let moving = cells.remove(at: fromIndex)
    if let targetIndex = cells.firstIndex(where: { $0.id == targetID }) {
      cells.insert(moving, at: targetIndex)
    } else {
      cells.append(moving)
    }
  }

  // MARK: - Önbellek

  private func prefetch(around pageID: Int) {
    let lower = max(1, pageID - prefetchRadius)
    let upper = min(fileInfo.pageCount, pageID + prefetchRadius)
    guard lower <= upper else { return }
    cache.prefetch(for: fileInfo.url, pages: lower..<(upper + 1), maxPixel: thumbMaxPixel)
  }

  // MARK: - Uygula

  private func apply() {
    let kept = cells.filter { !$0.isDeleted }
    let pageOrder = kept.map { String($0.id) }.joined(separator: ",")
    let rotations = kept.filter(\.isRotated).map { "\($0.id):\($0.targetRotation)" }
      .joined(separator: ",")
    onApply(pageOrder, rotations)
  }
}

/// Tek bir ızgara hücresi: küçük resim (yer tutuculu), seçim çerçevesi, silinmişlik göstergesi ve
/// "geri al" düğmesi. Küçük resim `cache`'ten `.task(id:)` ile yüklenir — sayfa (kimlik)
/// değişmedikçe yeniden istenmez; döndürme/silme yalnız görüntüyü etkiler, önbellek isteğini
/// TETİKLEMEZ.
private struct PageCellView: View {
  fileprivate let cell: PageGridView.Cell
  let url: URL
  let cache: PageThumbnailCache
  let maxPixel: Int
  let width: CGFloat
  let height: CGFloat
  let isSelected: Bool
  let isDropTarget: Bool
  let onTap: () -> Void
  let onRestore: () -> Void

  @State private var thumbnail: CGImage?

  private var isQuarterTurn: Bool { cell.extraSteps % 2 != 0 }
  private var rotationDegrees: Double { Double(cell.extraSteps) * 90 }

  var body: some View {
    VStack(spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .textBackgroundColor))
        if let thumbnail {
          Image(decorative: thumbnail, scale: 1, orientation: .up)
            .resizable()
            .aspectRatio(contentMode: .fit)
            // 90/270°'de görüntü ÖNCE kendi ekseninde ters en-boyla ölçeklenir, SONRA döndürülür —
            // böylece dönmüş hâli yine hücre kutusuna (width×height) sığar, taşmaz/kırpılmaz.
            .frame(
              width: isQuarterTurn ? height - 16 : width - 16,
              height: isQuarterTurn ? width - 16 : height - 16)
            .rotationEffect(.degrees(rotationDegrees))
            .opacity(cell.isDeleted ? 0.32 : 1)
        } else {
          ProgressView().controlSize(.small)
        }
        if cell.isDeleted {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 26))
            .foregroundStyle(.red.opacity(0.9))
        }
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(
            isDropTarget || isSelected ? Color.accentColor : .clear,
            lineWidth: isDropTarget ? 4 : 3)
      )
      .overlay(alignment: .topTrailing) {
        if cell.isDeleted {
          Button(action: onRestore) {
            Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 18))
          }
          .buttonStyle(.plain)
          .padding(5)
          .help("Restore this page")
        }
      }
      Text("\(cell.id)")
        .font(.caption)
        .foregroundStyle(cell.isDeleted ? .secondary : .primary)
        .strikethrough(cell.isDeleted)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    .task(id: cell.id) {
      thumbnail = await cache.thumbnail(for: url, page: cell.id, maxPixel: maxPixel)
    }
  }
}
