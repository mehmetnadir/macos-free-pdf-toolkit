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

  /// Toplu koşunun genel ilerlemesi (bkz. `batchProgress`). Dosya BAŞINA ilerleme satırda
  /// zaten görünüyor; bu, "20 dosyanın kaçındayım" sorusunu cevaplar.
  struct BatchProgress: Equatable {
    let completed: Int
    let total: Int
    let fraction: Double
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
  /// Sayfa küçük resimleri için TEK örnek — uygulama ömrü boyunca yaşar, her sheet açılışında
  /// yeniden kurulmaz (bkz. `.claude/CLAUDE.md`): aynı belge için render sonuçlarının bellek/disk
  /// önbelleğinde kalıcı kalmasını istiyoruz, sheet başına yeni bir örnek bunu sıfırlardı.
  let thumbnailCache = PageThumbnailCache()
  /// "Sayfa Düzenle" ızgara sheet'i açık mı ve hangi dosya için (bkz. `beginPageEdit`).
  var isShowingPageGridEditor = false
  /// Kurulum yönlendirme sayfası açık mı ve hangi araç için (bkz. `ToolSetupSheet`).
  var pendingToolRequirement: ToolRequirement?
  private(set) var pageGridTargetID: FileItem.ID?

  /// Son koşunun çıktı hedefi — "Show Folder" düğmesi ve hedef açıklaması bunu okur.
  private(set) var lastDestination: OutputDestination?
  /// Bu koşuda işlenen dosyaların kimlikleri. Genel ilerleme yalnız BUNLARA bakar — listede
  /// önceki koşulardan kalan `.done` öğeler sayıma karışmamalı.
  private(set) var runIDs: [FileItem.ID] = []

  private var runTask: Task<Void, Never>?
  /// Kullanıcı bir eylem kartına ELLE dokundu mu (bkz. `selectOperation`) — dokunduysa
  /// `recomputeSuggestedOperation()` artık `selectedOperationID`'yi EZMEZ. Liste tamamen
  /// boşalınca sıfırlanır: bir sonraki dosya grubu sıfırdan önerilsin (bkz. görev tanımı, Tur 3).
  private var userSelectedOperation = false

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

  /// "Sayfa Düzenle" sheet'inin düzenlediği dosya — `beginPageEdit()` ile atanır.
  var pageGridTargetItem: FileItem? {
    guard let pageGridTargetID else { return nil }
    return items.first { $0.id == pageGridTargetID }
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
  /// Ghostscript ŞU AN kurulu mu. Saklanmaz, her sorulduğunda yeniden ölçülür: kullanıcı
  /// uygulama açıkken Terminal'den kurabiliyor ve "Check Again" bunun üstüne kurulu.
  /// `CompressOperation` ile AYNI kaynağa bakar — iki ayrı arama listesi tutmuyoruz.
  var hasGhostscript: Bool { EngineLocator.ghostscript() != nil }

  /// Seçili işlem + seçili seçenek, kurulu olmayan bir dış araç gerektiriyor mu?
  /// Şimdilik tek vaka: Sıkıştır'ın "strong" kademesi. Kart soluk DEĞİL — kullanıcı seçebilsin
  /// ve ne yapması gerektiğini öğrensin; engel çalıştırma anında değil, burada anlatılıyor.
  var missingToolForCurrentSelection: ToolRequirement? {
    guard selectedOperationID == CompressOperation.identifier else { return nil }
    let level = optionValues[selectedOperationID]?[CompressOperation.levelOptionID]
      ?? CompressOperation().options.first?.defaultValue
    guard level == "strong", !hasGhostscript else { return nil }
    return .ghostscript
  }

  var hasRequiredEngine: Bool {
    if isTrimSelected { return hasTrimEngine }
    if requiresQPDFOnly { return hasQPDF }
    if isImageExportSelected { return true }
    return hasEngine
  }
  var missingEngineMessage: String {
    if isTrimSelected { return "Ghostscript required — brew install ghostscript" }
    if requiresQPDFOnly { return "qpdf engine not found" }
    return "No PDF engine found"
  }
  /// Şifre alanı yalnızca Kilit Aç için anlamlı; diğer işlemler şifre kabul etmiyor.
  var needsPassword: Bool {
    selectedOperationID == UnlockOperation.identifier
      && items.contains { $0.info.lockState == .passwordRequired }
  }
  /// Seçili işlem GERÇEKTEN uygulanabilir mi (bkz. `PDFOperation.applicability`) — kartın soluk/
  /// tıklanamaz durumuyla aynı gerçeği kullanır; `hasRequiredEngine` Birleştir/Parçala'nın qpdf
  /// kontrolünü ayrıca sağlar (Kesim Payını At'ın motor kontrolü artık `applicability`'nin İÇİNDE).
  var canRun: Bool {
    guard hasRequiredEngine, !isRunning else { return false }
    guard items.contains(where: { $0.status.isPending }) else { return false }
    if case .applicable = operation.applicability(for: items.map(\.info)) { return true }
    return false
  }

  /// Dosya listesinin üstünde gösterilen tek satırlık ön analiz — yalnız geçerli parçalar
  /// yazılır (bkz. görev tanımı, Tur 3). Dosya yoksa `nil` (satır hiç gösterilmez).
  var analysisSummary: String? {
    guard !items.isEmpty else { return nil }
    var parts = [counted(items.count, "file")]
    let totalPages = items.reduce(0) { $0 + $1.info.pageCount }
    if totalPages > 0 { parts.append(counted(totalPages, "page")) }
    let lockedCount = items.filter {
      $0.info.lockState == .restricted || $0.info.lockState == .passwordRequired
    }.count
    if lockedCount > 0 { parts.append("\(lockedCount) encrypted") }
    let bleedItems = items.filter { $0.info.hasBleed }
    if !bleedItems.isEmpty, let inset = bleedItems.first?.info.bleedInsetPoints {
      let mm = Double(inset) / 72 * 25.4
      let formatted = mm.formatted(
        .number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
      parts.append("\(formatted) mm bleed on \(counted(bleedItems.count, "file"))")
    }
    return parts.joined(separator: " · ")
  }

  var summary: String? {
    let done = items.filter { $0.status.isDone }.count
    let failed = items.filter { $0.status.isFailed }.count
    guard done + failed > 0 else { return nil }
    var parts = ["\(done) done"]
    if failed > 0 { parts.append("\(failed) failed") }
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
    recomputeSuggestedOperation()
  }

  func remove(_ id: FileItem.ID) {
    guard !isRunning else { return }
    items.removeAll { $0.id == id }
    recomputeSuggestedOperation()
  }

  func clear() {
    guard !isRunning else { return }
    items.removeAll()
    recomputeSuggestedOperation()
  }

  // MARK: - İşlem (eylem kartı) seçimi

  /// Bir eylem kartına tıklanınca çağrılır: seçimi ELLE yapıldı olarak işaretler — bkz.
  /// `recomputeSuggestedOperation`, bir sonraki dosya ekleme/çıkarmada bu seçim EZİLMEZ.
  func selectOperation(_ id: String) {
    guard OperationRegistry.operation(withID: id) != nil else { return }
    selectedOperationID = id
    userSelectedOperation = true
  }

  /// Dosya listesi her değiştiğinde (ekleme/çıkarma/temizleme) çağrılır. Kullanıcı ELLE bir kart
  /// seçmediyse `OperationRegistry.suggested(for:)`'a göre öne çıkan işlemi otomatik seçer. Liste
  /// tamamen boşalırsa elle-seçim bayrağı sıfırlanır — bir sonraki dosya grubu sıfırdan önerilsin.
  private func recomputeSuggestedOperation() {
    guard !items.isEmpty else {
      userSelectedOperation = false
      return
    }
    guard !userSelectedOperation else { return }
    if let suggested = OperationRegistry.suggested(for: items.map(\.info)) {
      selectedOperationID = suggested.id
    }
  }

  func pickFiles() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.message = "Choose PDF files or folders"
    panel.prompt = "Add"
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    Task { await add(urls: urls) }
  }

  /// Koşu sürerken genel ilerleme; koşu yokken `nil`.
  ///
  /// `.combined` (Birleştir) kipinde tüm dosyalar aynı anda aynı kesirle `.running` olur:
  /// toplam N, uçuştaki kesir ≈ N × f, tamamlanan 0 → sonuç ≈ f. Yani aynı formül iki kip
  /// için de doğru sonucu verir, ayrı dal gerekmiyor.
  var batchProgress: BatchProgress? {
    guard isRunning, !runIDs.isEmpty else { return nil }
    var completed = 0
    var inFlight: [Double] = []
    for id in runIDs {
      guard let item = items.first(where: { $0.id == id }) else { continue }
      switch item.status {
      case .done, .skipped, .failed: completed += 1
      case .running(let fraction): inFlight.append(fraction ?? 0)
      case .pending: break
      }
    }
    let total = runIDs.count
    return BatchProgress(
      completed: completed, total: total,
      fraction: BatchProgressMath.fraction(
        completed: completed, inFlight: inFlight, total: total))
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
    // Çıktı hedefi koşudan ÖNCE seçilir: üst-düzey çıktı sayısı 1'den fazlaysa orijinalin
    // yanında toplu klasör açılır (bkz. OutputPlacement.resolve).
    let pendingInfos = items.filter { $0.status.isPending }.map(\.info)
    let expectedOutputs = op.arity == .combined ? 1 : pendingInfos.count
    let destination = OutputPlacement.resolve(
      inputs: pendingInfos.map(\.url), operationTitle: op.title,
      expectedTopLevelOutputs: expectedOutputs)
    lastDestination = destination
    let context = OperationContext(
      password: password.isEmpty ? nil : password, outputDirectory: destination.directory,
      options: resolvedOptions)
    isRunning = true
    runTask = Task {
      defer {
        isRunning = false
        runTask = nil
      }
      let pendingIDs = items.filter { $0.status.isPending }.map(\.id)
      self.runIDs = pendingIDs
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
              update(id, .skipped("merged → \(mergedName)"))
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
      if !Task.isCancelled {
        NSSound(named: "Glass")?.play()
        finishRun(destination: destination)
      }
    }
  }

  /// Koşu bittiğinde çağrılır. Hiç çıktı üretilmediyse bu koşuda açılan boş toplu klasörü geri
  /// alır; üretildiyse Finder'ı YALNIZCA uygulama hâlâ öndeyse açar.
  ///
  /// Odak asla çalınmaz (bkz. `.claude/CLAUDE.md`): kullanıcı bu sırada başka bir işe geçtiyse
  /// Finder penceresini yüzüne açmak işini böler. O durumda Dock ikonu bir kez zıplar ve sonuç
  /// satırındaki "Show" düğmesi kullanıcıyı bekler. Bildirim izni İSTENMEZ — ilk açılışta izin
  /// sormak bu küçük araç için orantısız.
  private func finishRun(destination: OutputDestination) {
    let produced = items.flatMap { item -> [URL] in
      if case .done(let urls, _) = item.status { return urls }
      return []
    }
    guard !produced.isEmpty else {
      OutputPlacement.discardIfEmpty(destination)
      return
    }
    if NSApp.isActive {
      let target = destination.batchFolderName == nil ? produced : [destination.directory]
      NSWorkspace.shared.activateFileViewerSelecting(target)
    } else {
      NSApp.requestUserAttention(.informationalRequest)
    }
  }

  func cancel() {
    runTask?.cancel()
  }

  /// "Sayfaları Uygula" düğmesi Sayfa Düzenle işleminde basıldığında pipeline'ı HEMEN başlatmaz —
  /// önce ızgara sheet'ini açar. İlk BEKLEYEN dosya hedef alınır; kullanıcı seçmez (görev tanımı:
  /// listede birden çok dosya varken hangisini düzenleyeceği sorulmaz).
  func beginPageEdit() {
    guard !isRunning, let target = items.first(where: { $0.status.isPending }) else { return }
    pageGridTargetID = target.id
    isShowingPageGridEditor = true
  }

  /// Sheet'ten gelen planı uygular: yalnız `targetID` çalışır, listedeki DİĞER bekleyen dosyalar
  /// "tek dosyada çalışır" notuyla `.skipped` işaretlenir (görev tanımı) — sayfa düzenleme tek bir
  /// belgenin sayfa sayısına göre kurulmuş bir plandır, başka dosyaya anlamlı uygulanamaz.
  func applyPageEdit(targetID: FileItem.ID, pageOrder: String, rotations: String) {
    guard !isRunning, let info = items.first(where: { $0.id == targetID })?.info else { return }
    let otherPendingIDs = items.filter { $0.status.isPending && $0.id != targetID }.map(\.id)
    for id in otherPendingIDs { update(id, .skipped("page editing works on a single file")) }

    var options: [String: String] = [PageEditOperation.pageOrderOptionID: pageOrder]
    if !rotations.isEmpty { options[PageEditOperation.rotationsOptionID] = rotations }
    let context = OperationContext(options: options)

    isRunning = true
    runIDs = [targetID]
    update(targetID, .running(nil))
    runTask = Task {
      defer {
        isRunning = false
        runTask = nil
      }
      do {
        let outcome = try await PageEditOperation().run(file: info, context: context) { fraction in
          Task { @MainActor in self.update(targetID, .running(fraction)) }
        }
        switch outcome {
        case .produced(let urls, let note): update(targetID, .done(urls, note: note))
        case .skipped(let reason): update(targetID, .skipped(reason))
        }
      } catch is CancellationError {
        update(targetID, .pending)
      } catch {
        update(targetID, .failed(error.localizedDescription))
      }
      if !Task.isCancelled {
        NSSound(named: "Glass")?.play()
        // Sayfa Düzenle tek dosya üretir: toplu klasör yok, çıktı orijinalin yanında.
        finishRun(
          destination: OutputDestination(
            directory: info.url.deletingLastPathComponent(), batchFolderName: nil,
            usedFallback: false, note: nil))
      }
    }
  }

  private func update(_ id: FileItem.ID, _ status: ItemStatus) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].status = status
  }
}
