import CoreGraphics
import Foundation

/// Tek dosyayı çok dosyaya böler. Motor: qpdf. Üç kip (bkz. `options`):
/// - "each": her sayfa ayrı dosya (`--split-pages=1`)
/// - "n": N sayfalık parçalar (`--split-pages=N`)
/// - "half": ortadan iki parçaya böler (tek `--pages` aralık çağrısı × 2)
/// Çıktılar `<ad>_parts/` alt klasörüne yazılır (kaynağın yanına ya da seçilen klasöre).
public struct SplitOperation: PDFOperation {
  public static let identifier = "split"
  public let id = SplitOperation.identifier
  public let title = "Split"
  public let subtitle = "Splits the file into page groups"
  public let systemImage = "scissors"
  public let actionTitle = "Split"
  public let outputSuffix = "_parts"

  public static let modeOptionID = "mode"
  public static let pageCountOptionID = "n"

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.modeOptionID, label: "Mode",
        choices: [
          ("each", "Every page separate"), ("n", "N-page chunks"), ("half", "Split in half"),
        ],
        defaultValue: "each"),
      OperationOption(
        id: Self.pageCountOptionID, label: "Chunk Size",
        choices: [
          ("2", "2 pages"), ("5", "5 pages"), ("10", "10 pages"), ("20", "20 pages"),
          ("50", "50 pages"),
        ],
        defaultValue: "10"),
    ]
  }

  public init() {}

  /// En az iki sayfalı dosya sayısına bakar (`run()`'daki `file.pageCount > 1` kontrolüyle aynı
  /// eşik — tek sayfalık bir dosya bölünemez).
  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    guard !files.isEmpty else { return .notApplicable(reason: "Add a PDF first") }
    let eligible = files.filter { $0.pageCount > 1 }.count
    guard eligible > 0 else {
      return .notApplicable(reason: "Needs at least two pages to split")
    }
    return .applicable(fileCount: eligible)
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable: throw OperationError.unreadable
    case .passwordRequired: throw OperationError.passwordRequired
    case .restricted, .none: break
    }
    guard file.pageCount > 1 else {
      return .skipped(reason: "Not enough pages to split")
    }
    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf engine not found")
    }

    let mode = context.options[Self.modeOptionID] ?? "each"
    let outputDir = OutputNaming.uniqueDirectory(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partialDir = outputDir.deletingLastPathComponent()
      .appendingPathComponent(".\(outputDir.lastPathComponent).part", isDirectory: true)
    let fm = FileManager.default
    try? fm.removeItem(at: partialDir)
    try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)

    let stem = file.url.deletingPathExtension().lastPathComponent
    progress(0)
    var outputs: [URL] = []
    do {
      switch mode {
      case "half":
        let firstCount = Int((Double(file.pageCount) / 2).rounded(.up))
        let part1 = partialDir.appendingPathComponent("\(stem)-1.pdf")
        let part2 = partialDir.appendingPathComponent("\(stem)-2.pdf")
        try await extractRange(qpdf: qpdf, input: file.url, range: "1-\(firstCount)", output: part1)
        progress(0.5)
        try await extractRange(
          qpdf: qpdf, input: file.url, range: "\(firstCount + 1)-\(file.pageCount)", output: part2)
        outputs = [part1, part2]
      default:
        let n: Int
        if mode == "n", let parsed = Int(context.options[Self.pageCountOptionID] ?? "") {
          n = max(1, parsed)
        } else {
          n = 1  // "each" kipi
        }
        let template = partialDir.appendingPathComponent("\(stem).pdf")
        let arguments = ["--split-pages=\(n)", file.url.path, template.path]
        let result = try await ProcessRunner.run(qpdf, arguments: arguments)
        guard result.status == 0 || result.status == 3 else {
          throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
        }
        outputs =
          (try fm.contentsOfDirectory(at: partialDir, includingPropertiesForKeys: nil))
          .filter { $0.pathExtension.lowercased() == "pdf" }
          .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      }
    } catch is CancellationError {
      try? fm.removeItem(at: partialDir)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partialDir)
      throw error
    }
    progress(0.95)

    // Kanıt: en az bir parça, hiçbiri 0 sayfa değil, toplam == kaynağın sayfa sayısı.
    guard SplitVerification.verify(outputs, expectedTotal: file.pageCount) else {
      try? fm.removeItem(at: partialDir)
      throw OperationError.splitVerificationFailed
    }

    try fm.moveItem(at: partialDir, to: outputDir)
    progress(1)
    let finalOutputs = outputs.map { outputDir.appendingPathComponent($0.lastPathComponent) }
    return .produced(urls: finalOutputs, note: nil)
  }

  private func extractRange(qpdf: URL, input: URL, range: String, output: URL) async throws {
    let arguments = ["--empty", "--pages", input.path, range, "--", output.path]
    let result = try await ProcessRunner.run(qpdf, arguments: arguments)
    guard result.status == 0 || result.status == 3 else {
      throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
    }
  }
}
