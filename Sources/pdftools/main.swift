import Foundation
import PDFToolsCore

func usage() -> Never {
  print(
    """
    kullanım:
      pdftools unlock [--password ŞİFRE] [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools trim [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools merge [--out KLASÖR] <dosya.pdf>...
      pdftools split [--mode her|n:10|ikiye] [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools image [--format png|jpeg|heic] [--dpi 150] [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools engines
    """)
  exit(64)
}

/// Tüm alt komutların ortak sonuç yazdırması: her biri `OperationOutcome` üretir.
func report(_ fileName: String, _ outcome: OperationOutcome) {
  switch outcome {
  case .produced(let outputs, let note):
    let names =
      outputs.count == 1
      ? outputs[0].lastPathComponent
      : "\(outputs.count) dosya → \(outputs[0].deletingLastPathComponent().lastPathComponent)/"
    if let note {
      print("✓ \(fileName) → \(names) (\(note))")
    } else {
      print("✓ \(fileName) → \(names)")
    }
  case .skipped(let reason):
    print("– \(fileName): \(reason)")
  }
}

/// unlock/trim/split/image ortak döngü: her girdi dosyasını `operation.run` ile ayrı ayrı işler.
func runPerFile(
  _ operation: any PDFOperation, files: [URL], context: OperationContext
) async -> Int32 {
  var failures = 0
  for url in files {
    let info = PDFFileInfo.inspect(url)
    do {
      let outcome = try await operation.run(file: info, context: context) { _ in }
      report(info.fileName, outcome)
    } catch {
      failures += 1
      print("✗ \(info.fileName): \(error.localizedDescription)")
    }
  }
  return failures == 0 ? 0 : 1
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

/// Ortak seçenek ayrıştırıcı: `--out`/`-o` ve düz konumsal argümanları (dosya/klasör) ayırır;
/// `extra` ile alt komuta özgü bayraklar (ör. `--password`, `--mode`) işlenir.
func parseArguments(
  _ arguments: [String], extra: (String, inout Int) -> Bool = { _, _ in false }
) -> (outputDirectory: URL?, inputs: [URL]) {
  var outputDirectory: URL?
  var inputs: [URL] = []
  var index = 1
  while index < arguments.count {
    let arg = arguments[index]
    if arg == "--out" || arg == "-o" {
      index += 1
      guard index < arguments.count else { usage() }
      outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
    } else if extra(arg, &index) {
      // extra(_:_:) kendi değerini tükettiyse index'i ileri almış olur.
    } else {
      inputs.append(URL(fileURLWithPath: arg))
    }
    index += 1
  }
  return (outputDirectory, inputs)
}

switch command {
case "engines":
  let engines = EngineLocator.availableEngines()
  for engine in engines { print("\(engine.name)\t\(engine.executable.path)") }
  if let gs = EngineLocator.trimEngine() {
    print("\(gs.name)\t\(gs.executable.path)")
  } else {
    print("gs\t(bulunamadı — Kesim Payını At devre dışı; brew install ghostscript)")
  }
  if engines.isEmpty {
    print("motor yok — packaging/build-engines.sh çalıştır")
    exit(1)
  }

case "unlock":
  var password: String?
  let (outputDirectory, inputs) = parseArguments(arguments) { arg, index in
    guard arg == "--password" || arg == "-p" else { return false }
    index += 1
    guard index < arguments.count else { usage() }
    password = arguments[index]
    return true
  }
  let files = PDFFileInfo.collectPDFs(from: inputs)
  guard !files.isEmpty else { usage() }
  let context = OperationContext(password: password, outputDirectory: outputDirectory)
  exit(await runPerFile(UnlockOperation(), files: files, context: context))

case "trim":
  let (outputDirectory, inputs) = parseArguments(arguments)
  let files = PDFFileInfo.collectPDFs(from: inputs)
  guard !files.isEmpty else { usage() }
  let context = OperationContext(outputDirectory: outputDirectory)
  exit(await runPerFile(TrimOperation(), files: files, context: context))

case "merge":
  let (outputDirectory, inputs) = parseArguments(arguments)
  let files = PDFFileInfo.collectPDFs(from: inputs)
  guard files.count > 1 else { usage() }
  let infos = files.map(PDFFileInfo.inspect)
  let context = OperationContext(outputDirectory: outputDirectory)
  do {
    let outcome = try await MergeOperation().runCombined(files: infos, context: context) { _ in }
    report(infos.map(\.fileName).joined(separator: " + "), outcome)
    exit(0)
  } catch {
    print("✗ birleştirme: \(error.localizedDescription)")
    exit(1)
  }

case "split":
  var modeArgument = "her"
  let (outputDirectory, inputs) = parseArguments(arguments) { arg, index in
    guard arg == "--mode" || arg == "-m" else { return false }
    index += 1
    guard index < arguments.count else { usage() }
    modeArgument = arguments[index]
    return true
  }
  var options: [String: String] = [:]
  if modeArgument.hasPrefix("n:") {
    options[SplitOperation.modeOptionID] = "n"
    options[SplitOperation.pageCountOptionID] = String(modeArgument.dropFirst(2))
  } else {
    options[SplitOperation.modeOptionID] = modeArgument
  }
  let files = PDFFileInfo.collectPDFs(from: inputs)
  guard !files.isEmpty else { usage() }
  let context = OperationContext(outputDirectory: outputDirectory, options: options)
  exit(await runPerFile(SplitOperation(), files: files, context: context))

case "image":
  var format = "png"
  var dpi = "150"
  let (outputDirectory, inputs) = parseArguments(arguments) { arg, index in
    if arg == "--format" || arg == "-f" {
      index += 1
      guard index < arguments.count else { usage() }
      format = arguments[index]
      return true
    }
    if arg == "--dpi" || arg == "-d" {
      index += 1
      guard index < arguments.count else { usage() }
      dpi = arguments[index]
      return true
    }
    return false
  }
  let files = PDFFileInfo.collectPDFs(from: inputs)
  guard !files.isEmpty else { usage() }
  let context = OperationContext(
    outputDirectory: outputDirectory,
    options: [ImageExportOperation.formatOptionID: format, ImageExportOperation.dpiOptionID: dpi])
  exit(await runPerFile(ImageExportOperation(), files: files, context: context))

default:
  usage()
}
