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
    case done(URL)
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
  var isRunning = false
  var isInspecting = false
  let engineNames: [String]

  private var runTask: Task<Void, Never>?

  init() {
    engineNames = EngineLocator.availableEngines().map(\.name)
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
  var needsPassword: Bool { items.contains { $0.info.lockState == .passwordRequired } }
  var canRun: Bool { hasEngine && !isRunning && items.contains { $0.status.isPending } }

  var summary: String? {
    let done = items.filter { $0.status.isDone }.count
    let failed = items.filter { $0.status.isFailed }.count
    guard done + failed > 0 else { return nil }
    var parts = ["\(done) tamam"]
    if failed > 0 { parts.append("\(failed) hata") }
    return parts.joined(separator: " · ")
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
    let context = OperationContext(password: password.isEmpty ? nil : password)
    let op = operation
    isRunning = true
    runTask = Task {
      defer {
        isRunning = false
        runTask = nil
      }
      for id in items.filter({ $0.status.isPending }).map(\.id) {
        if Task.isCancelled { break }
        guard let info = items.first(where: { $0.id == id })?.info else { continue }
        update(id, .running(nil))
        do {
          let outcome = try await op.run(file: info, context: context) { fraction in
            Task { @MainActor in self.update(id, .running(fraction)) }
          }
          switch outcome {
          case .produced(let url): update(id, .done(url))
          case .skipped(let reason): update(id, .skipped(reason))
          }
        } catch is CancellationError {
          update(id, .pending)
          break
        } catch {
          update(id, .failed(error.localizedDescription))
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
