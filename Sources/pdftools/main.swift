import Foundation
import PDFToolsCore

func usage() -> Never {
  print(
    """
    kullanım:
      pdftools unlock [--password ŞİFRE] [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools trim [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools engines
    """)
  exit(64)
}

/// unlock/trim ortak sonuç yazdırma: her iki alt komut da `OperationOutcome` üretir.
func report(_ fileName: String, _ outcome: OperationOutcome) {
  switch outcome {
  case .produced(let output, let note):
    if let note {
      print("✓ \(fileName) → \(output.lastPathComponent) (\(note))")
    } else {
      print("✓ \(fileName) → \(output.lastPathComponent)")
    }
  case .skipped(let reason):
    print("– \(fileName): \(reason)")
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

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
  var outputDirectory: URL?
  var inputs: [URL] = []
  var index = 1
  while index < arguments.count {
    let arg = arguments[index]
    switch arg {
    case "--password", "-p":
      index += 1
      guard index < arguments.count else { usage() }
      password = arguments[index]
    case "--out", "-o":
      index += 1
      guard index < arguments.count else { usage() }
      outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
    default:
      inputs.append(URL(fileURLWithPath: arg))
    }
    index += 1
  }
  let files = PDFFileInfo.collectPDFs(from: inputs)
  guard !files.isEmpty else { usage() }

  let operation = UnlockOperation()
  let context = OperationContext(password: password, outputDirectory: outputDirectory)
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
  exit(failures == 0 ? 0 : 1)

case "trim":
  var outputDirectory: URL?
  var inputs: [URL] = []
  var index = 1
  while index < arguments.count {
    let arg = arguments[index]
    switch arg {
    case "--out", "-o":
      index += 1
      guard index < arguments.count else { usage() }
      outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
    default:
      inputs.append(URL(fileURLWithPath: arg))
    }
    index += 1
  }
  let files = PDFFileInfo.collectPDFs(from: inputs)
  guard !files.isEmpty else { usage() }

  let operation = TrimOperation()
  let context = OperationContext(outputDirectory: outputDirectory)
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
  exit(failures == 0 ? 0 : 1)

default:
  usage()
}
