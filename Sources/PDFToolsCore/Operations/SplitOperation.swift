import CoreGraphics
import Foundation

/// Tek dosyayı çok dosyaya böler. Motor: qpdf. Üç kip (bkz. `options`):
/// - "her": her sayfa ayrı dosya (`--split-pages=1`)
/// - "n": N sayfalık parçalar (`--split-pages=N`)
/// - "ikiye": ortadan iki parçaya böler (tek `--pages` aralık çağrısı × 2)
/// Çıktılar `<ad>_parca/` alt klasörüne yazılır (kaynağın yanına ya da seçilen klasöre).
public struct SplitOperation: PDFOperation {
  public static let identifier = "split"
  public let id = SplitOperation.identifier
  public let title = "Parçala"
  public let subtitle = "Dosyayı sayfa gruplarına böler"
  public let systemImage = "scissors"
  public let actionTitle = "Parçala"
  public let outputSuffix = "_parca"

  public static let modeOptionID = "mode"
  public static let pageCountOptionID = "n"

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.modeOptionID, label: "Kip",
        choices: [("her", "Her sayfa ayrı"), ("n", "N sayfalık parçalar"), ("ikiye", "İkiye böl")],
        defaultValue: "her"),
      OperationOption(
        id: Self.pageCountOptionID, label: "Parça Boyutu",
        choices: [("2", "2 sayfa"), ("5", "5 sayfa"), ("10", "10 sayfa"), ("20", "20 sayfa"), ("50", "50 sayfa")],
        defaultValue: "10"),
    ]
  }

  public init() {}

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
      return .skipped(reason: "Bölünecek yeterli sayfa yok")
    }
    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf motoru bulunamadı")
    }

    let mode = context.options[Self.modeOptionID] ?? "her"
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
      case "ikiye":
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
          n = 1  // "her" kipi
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
