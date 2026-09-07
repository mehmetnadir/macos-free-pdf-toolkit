import AppKit
import PDFToolsCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
  enum ItemStatus: Equatable {
    case pending
    case running(Double?)
    /// `urls`: bu dosyadan üretilen çıktı(lar) — çoğu işlemde tek eleman, Parçala/Görüntüye
    /// Aktar'da birden çok. `note`: örn. kesim payında kalan iz oranı gibi ek bilgi; yoksa `nil`.
    case done([URL], note: String?)
    case skipped(String)
    case failed(String)

    var isPending: Bool { if case .pending = self { return true } else { return false } }
    var isDone: Bool { if case .done = self { return true } else { return false } }
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
  }

  struct FileItem: Identifiable, Equatable {
    let id = UUID()
    var info: PDFFileInfo
    var status: ItemStatus = .pending
  }

  var items: [FileItem] = []
  var selectedOperationID: String = UnlockOperation.identifier
  var password: String = ""
  /// İşlem seçenekleri, işlem başına saklanır (dıştaki anahtar `operationID`, içteki `optionID`) —
  /// işlem değiştirildiğinde diğerinin seçimleri sıfırlanmaz.
  var optionValues: [String: [String: String]] = [:]
  var isRunning = false
  var isInspecting = false
  let engineNames: [String]
  let hasTrimEngine: Bool
  let hasQPDF: Bool

  private var runTask: Task<Void, Never>?

  init() {
    engineNames = EngineLocator.availableEngines().map(\.name)
    hasTrimEngine = EngineLocator.trimEngine() != nil
    hasQPDF = EngineLocator.find("qpdf") != nil
    let launchURLs = CommandLine.arguments.dropFirst()
      .filter { $0.lowercased().hasSuffix(".pdf") }
      .map { URL(fileURLWithPath: $0) }
    if !launchURLs.isEmpty {
      Task { await add(urls: launchURLs) }
    }
  }

  var operation: any PDFOperation {
    OperationRegistry.operation(withID: selectedOperationID) ?? OperationRegistry.all[0]
  }

  var hasEngine: Bool { !engineNames.isEmpty }
  private var isTrimSelected: Bool { selectedOperationID == TrimOperation.identifier }
  /// Birleştir/Parçala yalnızca qpdf kullanır (pdfcpu yedeği yok, bkz. `.claude/CLAUDE.md`).
  private var requiresQPDFOnly: Bool {
    selectedOperationID == MergeOperation.identifier || selectedOperationID == SplitOperation.identifier
  }
  /// Görüntüye Aktar hiç alt süreç kullanmaz (yerleşik CoreGraphics/ImageIO) — motor gerektirmez.
  private var isImageExportSelected: Bool { selectedOperationID == ImageExportOperation.identifier }
  /// Seçili işlem için gereken motor kurulu mu.
  var hasRequiredEngine: Bool {
    if isTrimSelected { return hasTrimEngine }
    if requiresQPDFOnly { return hasQPDF }
    if isImageExportSelected { return true }
    return hasEngine
  }
  var missingEngineMessage: String {
    if isTrimSelected { return "Ghostscript gerekli — brew install ghostscript" }
    if requiresQPDFOnly { return "qpdf motoru bulunamadı" }
    return "PDF motoru bulunamadı"
  }
  /// Şifre alanı yalnızca Kilit Aç için anlamlı; diğer işlemler şifre kabul etmiyor.
  var needsPassword: Bool {
    selectedOperationID == UnlockOperation.identifier
      && items.contains { $0.info.lockState == .passwordRequired }
  }
  var canRun: Bool { hasRequiredEngine && !isRunning && items.contains { $0.status.isPending } }

  var summary: String? {
    let done = items.filter { $0.status.isDone }.count
    let failed = items.filter { $0.status.isFailed }.count
    guard done + failed > 0 else { return nil }
    var parts = ["\(done) tamam"]
    if failed > 0 { parts.append("\(failed) hata") }
    return parts.joined(separator: " · ")
  }

  /// Seçili işlemin bir seçeneği için mevcut değeri okuyan/yazan binding — ayarlanmamışsa
  /// seçeneğin kendi `defaultValue`'suna düşer.
  func optionBinding(for option: OperationOption) -> Binding<String> {
    Binding(
      get: { self.optionValues[self.selectedOperationID]?[option.id] ?? option.defaultValue },
      set: { self.optionValues[self.selectedOperationID, default: [:]][option.id] = $0 }
    )
  }

  // MARK: - Liste yönetimi

  func add(urls: [URL]) async {
    let known = Set(items.map(\.info.url))
    let candidates = PDFFileInfo.collectPDFs(from: urls).filter { !known.contains($0) }
    guard !candidates.isEmpty else { return }
    isInspecting = true
    defer { isInspecting = false }
    let infos = await Task.detached(priority: .userInitiated) {
      candidates.map(PDFFileInfo.inspect)
    }.value
    items += infos.map { FileItem(info: $0) }
  }

  func remove(_ id: FileItem.ID) {
    guard !isRunning else { return }
    items.removeAll { $0.id == id }
  }

  func clear() {
    guard !isRunning else { return }
    items.removeAll()
  }

  func pickFiles() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.message = "PDF dosyalarını ya da klasörleri seç"
    panel.prompt = "Ekle"
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    Task { await add(urls: urls) }
  }

  func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  // MARK: - Çalıştırma

  func run() {
    guard canRun else { return }
    let op = operation
    var resolvedOptions: [String: String] = [:]
    for option in op.options {
      resolvedOptions[option.id] = optionValues[selectedOperationID]?[option.id] ?? option.defaultValue
    }
    let context = OperationContext(password: password.isEmpty ? nil : password, options: resolvedOptions)
    isRunning = true
    runTask = Task {
      defer {
        isRunning = false
        runTask = nil
      }
      let pendingIDs = items.filter { $0.status.isPending }.map(\.id)
      switch op.arity {
      case .perFile:
        for id in pendingIDs {
          if Task.isCancelled { break }
          guard let info = items.first(where: { $0.id == id })?.info else { continue }
          update(id, .running(nil))
          do {
            let outcome = try await op.run(file: info, context: context) { fraction in
              Task { @MainActor in self.update(id, .running(fraction)) }
            }
            switch outcome {
            case .produced(let urls, let note): update(id, .done(urls, note: note))
            case .skipped(let reason): update(id, .skipped(reason))
            }
          } catch is CancellationError {
            update(id, .pending)
            break
          } catch {
            update(id, .failed(error.localizedDescription))
          }
        }
      case .combined:
        // Tüm bekleyen dosyalar TEK çağrıda işlenir. Sonuç hepsine yansıtılır: başarıda ilk
        // öğe gerçek çıktıyı taşır (`.done`), geri kalanı "birleştirildi" notuyla `.skipped` —
        // kullanıcı listeye bakıp ne olduğunu anlamalı, sanki hiçbir şey olmamış gibi durmamalı.
        guard !pendingIDs.isEmpty else { break }
        for id in pendingIDs { update(id, .running(nil)) }
        let infos = pendingIDs.compactMap { id in items.first(where: { $0.id == id })?.info }
        do {
          let outcome = try await op.runCombined(files: infos, context: context) { fraction in
            Task { @MainActor in for id in pendingIDs { self.update(id, .running(fraction)) } }
          }
          switch outcome {
          case .produced(let urls, let note):
            if let first = pendingIDs.first {
              update(first, .done(urls, note: note))
            }
            let mergedName = urls.first?.lastPathComponent ?? ""
            for id in pendingIDs.dropFirst() {
              update(id, .skipped("birleştirildi → \(mergedName)"))
            }
          case .skipped(let reason):
            for id in pendingIDs { update(id, .skipped(reason)) }
          }
        } catch is CancellationError {
          for id in pendingIDs { update(id, .pending) }
        } catch {
          for id in pendingIDs { update(id, .failed(error.localizedDescription)) }
        }
      }
      if !Task.isCancelled { NSSound(named: "Glass")?.play() }
    }
  }

  func cancel() {
    runTask?.cancel()
  }

  private func update(_ id: FileItem.ID, _ status: ItemStatus) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].status = status
  }
}
