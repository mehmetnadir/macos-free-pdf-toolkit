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
      pdftools pageedit [--order 3,1,2] [--rotate 1:90,4:180] [--out KLASÖR] <dosya.pdf>...
      pdftools compress [--level light|strong|raster] [--dpi 150] [--quality 0.7]
                        [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools encrypt [--password ŞİFRE] [--owner-password ŞİFRE]
                       [--permissions all|noprint|nocopy|readonly] [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools linearize [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools repair [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools extractimages [--min-size 10000] [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools extracttext [--layout plain|pages] [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools qradd --content METİN [--position br|bl|tr|tl] [--size small|medium|large]
                     [--pages all|first] [--out KLASÖR] <dosya.pdf|klasör>...
      pdftools qrextract [--dpi 200] [--out KLASÖR] <dosya.pdf|klasör>...
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

case "compress":
  var seçenekler: [String: String] = [:]
  let (compressOut, compressInputs) = parseArguments(arguments) { arg, index in
    let eşleme = ["--level": CompressOperation.levelOptionID,
                  "--dpi": CompressOperation.dpiOptionID,
                  "--quality": CompressOperation.qualityOptionID]
    guard let anahtar = eşleme[arg] else { return false }
    index += 1
    guard index < arguments.count else { usage() }
    seçenekler[anahtar] = arguments[index]
    return true
  }
  let compressFiles = PDFFileInfo.collectPDFs(from: compressInputs)
  guard !compressFiles.isEmpty else { usage() }
  var compressContext = OperationContext(outputDirectory: compressOut)
  compressContext.options = seçenekler
  exit(await runPerFile(CompressOperation(), files: compressFiles, context: compressContext))

case "encrypt":
  var şifreSeçenekleri: [String: String] = [:]
  let (encryptOut, encryptInputs) = parseArguments(arguments) { arg, index in
    let eşleme = ["--password": EncryptOperation.userPasswordOptionID,
                  "-p": EncryptOperation.userPasswordOptionID,
                  "--owner-password": EncryptOperation.ownerPasswordOptionID,
                  "--permissions": EncryptOperation.permissionsOptionID]
    guard let anahtar = eşleme[arg] else { return false }
    index += 1
    guard index < arguments.count else { usage() }
    şifreSeçenekleri[anahtar] = arguments[index]
    return true
  }
  let encryptFiles = PDFFileInfo.collectPDFs(from: encryptInputs)
  guard !encryptFiles.isEmpty else { usage() }
  var encryptContext = OperationContext(outputDirectory: encryptOut)
  encryptContext.options = şifreSeçenekleri
  exit(await runPerFile(EncryptOperation(), files: encryptFiles, context: encryptContext))

case "linearize":
  let (linOut, linInputs) = parseArguments(arguments)
  let linFiles = PDFFileInfo.collectPDFs(from: linInputs)
  guard !linFiles.isEmpty else { usage() }
  exit(await runPerFile(
    LinearizeOperation(), files: linFiles,
    context: OperationContext(outputDirectory: linOut)))

case "repair":
  let (repairOut, repairInputs) = parseArguments(arguments)
  let repairFiles = PDFFileInfo.collectPDFs(from: repairInputs)
  guard !repairFiles.isEmpty else { usage() }
  exit(await runPerFile(
    RepairOperation(), files: repairFiles,
    context: OperationContext(outputDirectory: repairOut)))

case "extractimages":
  var görselSeçenekleri: [String: String] = [:]
  let (imgOut, imgInputs) = parseArguments(arguments) { arg, index in
    guard arg == "--min-size" else { return false }
    index += 1
    guard index < arguments.count else { usage() }
    görselSeçenekleri["minSize"] = arguments[index]
    return true
  }
  let imgFiles = PDFFileInfo.collectPDFs(from: imgInputs)
  guard !imgFiles.isEmpty else { usage() }
  var imgContext = OperationContext(outputDirectory: imgOut)
  imgContext.options = görselSeçenekleri
  exit(await runPerFile(ExtractImagesOperation(), files: imgFiles, context: imgContext))

case "extracttext":
  var metinSeçenekleri: [String: String] = [:]
  let (txtOut, txtInputs) = parseArguments(arguments) { arg, index in
    guard arg == "--layout" else { return false }
    index += 1
    guard index < arguments.count else { usage() }
    metinSeçenekleri["layout"] = arguments[index]
    return true
  }
  let txtFiles = PDFFileInfo.collectPDFs(from: txtInputs)
  guard !txtFiles.isEmpty else { usage() }
  var txtContext = OperationContext(outputDirectory: txtOut)
  txtContext.options = metinSeçenekleri
  exit(await runPerFile(ExtractTextOperation(), files: txtFiles, context: txtContext))

case "qradd":
  var qrSeçenekleri: [String: String] = [:]
  let (qrOut, qrInputs) = parseArguments(arguments) { arg, index in
    let eşleme = ["--content": QRAddOperation.contentOptionID,
                  "--position": QRAddOperation.positionOptionID,
                  "--size": QRAddOperation.sizeOptionID,
                  "--pages": QRAddOperation.pagesOptionID]
    guard let anahtar = eşleme[arg] else { return false }
    index += 1
    guard index < arguments.count else { usage() }
    qrSeçenekleri[anahtar] = arguments[index]
    return true
  }
  let qrFiles = PDFFileInfo.collectPDFs(from: qrInputs)
  guard !qrFiles.isEmpty else { usage() }
  var qrContext = OperationContext(outputDirectory: qrOut)
  qrContext.options = qrSeçenekleri
  exit(await runPerFile(QRAddOperation(), files: qrFiles, context: qrContext))

case "qrextract":
  var qrxSeçenekleri: [String: String] = [:]
  let (qrxOut, qrxInputs) = parseArguments(arguments) { arg, index in
    guard arg == "--dpi" else { return false }
    index += 1
    guard index < arguments.count else { usage() }
    qrxSeçenekleri["dpi"] = arguments[index]
    return true
  }
  let qrxFiles = PDFFileInfo.collectPDFs(from: qrxInputs)
  guard !qrxFiles.isEmpty else { usage() }
  var qrxContext = OperationContext(outputDirectory: qrxOut)
  qrxContext.options = qrxSeçenekleri
  exit(await runPerFile(QRExtractOperation(), files: qrxFiles, context: qrxContext))

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

case "pageedit":
  var pageOrder: String?
  var rotations: String?
  let (outputDirectory, inputs) = parseArguments(arguments) { arg, index in
    if arg == "--order" {
      index += 1
      guard index < arguments.count else { usage() }
      pageOrder = arguments[index]
      return true
    }
    if arg == "--rotate" {
      index += 1
      guard index < arguments.count else { usage() }
      rotations = arguments[index]
      return true
    }
    return false
  }
  // En az biri verilmeli — ikisi de eksikse CLI çağrısının bir anlamı yok (çekirdek katman
  // `pageOrder` yokluğunu "tüm sayfalar sırayla" sayar, ama bu CLI'da sessiz no-op olurdu).
  guard pageOrder != nil || rotations != nil else { usage() }
  let files = PDFFileInfo.collectPDFs(from: inputs)
  guard !files.isEmpty else { usage() }
  var options: [String: String] = [:]
  if let pageOrder { options[PageEditOperation.pageOrderOptionID] = pageOrder }
  if let rotations { options[PageEditOperation.rotationsOptionID] = rotations }
  let context = OperationContext(outputDirectory: outputDirectory, options: options)
  exit(await runPerFile(PageEditOperation(), files: files, context: context))

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
