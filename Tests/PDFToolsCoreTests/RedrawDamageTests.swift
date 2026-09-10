import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import PDFToolsCore

/// Sayfaları yeniden çizen `CoreGraphicsTrimEngine` motorunun gerçek matbaa PDF'lerine verdiği
/// hasarı (DeviceGray JPEG'lerin ICC profiline yeniden etiketlenmesi, XMP üstverisinin silinmesi,
/// sürümün düşürülmesi) ölçen testler.
///
/// NEDEN ELLE KURULMUŞ (hand-built) FIXTURE: CoreGraphics ile programatik üretilen PDF'ler bu
/// hasarı üretmez — CoreGraphics kendi yazdığı PDF'i okuyup yeniden yazarken yapıyı korur.
/// Hasar, bağımsız RIP/dizgi araçlarının ürettiği gerçek matbaa dosyalarında ortaya çıkar. Bu
/// yüzden burada bayt bayt elle kurulmuş minimal bir PDF 1.4 fixture kullanılır.
final class RedrawDamageTests: XCTestCase {
  override func setUp() {
    super.setUp()
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    EngineLocator.extraDirectories = [repoRoot.appendingPathComponent("vendor/bin")]
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdftools-damage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - Elle kurulan (hand-built) PDF Fixture üreticisi

  /// 32x32 boyutunda gri tonlamalı (DeviceGray) JPEG verisini ImageIO kullanarak üretir.
  private static func makeGrayscaleJPEGData() -> Data {
    let width = 32
    let height = 32
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        pixels[y * width + x] = UInt8((x + y) * 255 / (width + height - 2))
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else {
      fatalError("Gri tonlamalı CGImage oluşturulamadı")
    }

    let jpegData = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        jpegData, "public.jpeg" as CFString, 1, nil)
    else {
      fatalError("CGImageDestination oluşturulamadı")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      fatalError("CGImageDestination sonlandırılamadı")
    }
    return jpegData as Data
  }

  /// Minimal bir PDF 1.4 dosyasını bayt bayt elle kurar:
  /// - Klasik (akış olmayan) xref tablosu, ofsetler dinamik hesaplanır
  /// - 1 sayfa: MediaBox [0 0 200 300], TrimBox [20 20 180 280]
  /// - 1 görüntü XObject: /Subtype /Image, /ColorSpace /DeviceGray, /Filter /DCTDecode, /BitsPerComponent 8
  /// - 1 XMP akışı: /Type /Metadata, /Subtype /XML
  /// - İçerik akışı: görüntüyü hem kesim içine hem kesim payına taşacak biçimde çizer
  private static func makeHandBuiltFixtureData() -> Data {
    let jpegData = makeGrayscaleJPEGData()
    let xmpString = """
      <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
      <x:xmpmeta xmlns:x="adobe:ns:meta/">
       <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
         <dc:title>
          <rdf:Alt>
           <rdf:li xml:lang="x-default">Hand-built Damage Fixture</rdf:li>
          </rdf:Alt>
         </dc:title>
        </rdf:Description>
       </rdf:RDF>
      </x:xmpmeta>
      <?xpacket end="w"?>
      """
    let xmpData = Data(xmpString.utf8)

    // Görüntüyü kesim çizgisi (x:20..180, y:20..280) dışına taşıracak şekilde (x:10..170, y:10..210) çiziyoruz.
    let contentString = "q\n160 0 0 200 10 10 cm\n/Im0 Do\nQ\n"
    let contentData = Data(contentString.utf8)

    var buffer = Data()
    var offsets: [Int: Int] = [:]

    // 1. PDF Başlığı (%PDF-1.4 ve ikili yorum baytları)
    buffer.append(Data("%PDF-1.4\n".utf8))
    buffer.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))

    // Nesne 1: Katalog (/Catalog)
    offsets[1] = buffer.count
    let catObj = """
      1 0 obj
      <<
        /Type /Catalog
        /Pages 2 0 R
        /Metadata 6 0 R
      >>
      endobj\n
      """
    buffer.append(Data(catObj.utf8))

    // Nesne 2: Sayfalar (/Pages)
    offsets[2] = buffer.count
    let pagesObj = """
      2 0 obj
      <<
        /Type /Pages
        /Kids [3 0 R]
        /Count 1
      >>
      endobj\n
      """
    buffer.append(Data(pagesObj.utf8))

    // Nesne 3: Sayfa (/Page)
    offsets[3] = buffer.count
    let pageObj = """
      3 0 obj
      <<
        /Type /Page
        /Parent 2 0 R
        /MediaBox [0 0 200 300]
        /TrimBox [20 20 180 280]
        /Resources <<
          /XObject <<
            /Im0 5 0 R
          >>
        >>
        /Contents 4 0 R
      >>
      endobj\n
      """
    buffer.append(Data(pageObj.utf8))

    // Nesne 4: İçerik Akışı (/Contents)
    offsets[4] = buffer.count
    let contentHeader = "4 0 obj\n<<\n  /Length \(contentData.count)\n>>\nstream\n"
    buffer.append(Data(contentHeader.utf8))
    buffer.append(contentData)
    buffer.append(Data("\nendstream\nendobj\n".utf8))

    // Nesne 5: Görüntü XObject (/Subtype /Image, /ColorSpace /DeviceGray, /Filter /DCTDecode)
    offsets[5] = buffer.count
    let imageHeader = """
      5 0 obj
      <<
        /Type /XObject
        /Subtype /Image
        /Width 32
        /Height 32
        /ColorSpace /DeviceGray
        /BitsPerComponent 8
        /Filter /DCTDecode
        /Length \(jpegData.count)
      >>
      stream\n
      """
    buffer.append(Data(imageHeader.utf8))
    buffer.append(jpegData)
    buffer.append(Data("\nendstream\nendobj\n".utf8))

    // Nesne 6: XMP Üstveri Akışı (/Type /Metadata, /Subtype /XML)
    offsets[6] = buffer.count
    let xmpHeader = """
      6 0 obj
      <<
        /Type /Metadata
        /Subtype /XML
        /Length \(xmpData.count)
      >>
      stream\n
      """
    buffer.append(Data(xmpHeader.utf8))
    buffer.append(xmpData)
    buffer.append(Data("\nendstream\nendobj\n".utf8))

    // 7. xref Tablosu (klasik akış olmayan, tam 20 baytlık girdiler)
    let startXRef = buffer.count
    let objectCount = 6
    var xrefString = "xref\n0 \(objectCount + 1)\n"
    xrefString += "0000000000 65535 f \r\n"
    for objId in 1...objectCount {
      guard let offset = offsets[objId] else {
        fatalError("Eksik nesne ofseti: \(objId)")
      }
      xrefString += String(format: "%010ld 00000 n \r\n", offset)
    }

    let trailerString = """
      trailer
      <<
        /Size \(objectCount + 1)
        /Root 1 0 R
      >>
      startxref
      \(startXRef)
      %%EOF\n
      """

    buffer.append(Data(xrefString.utf8))
    buffer.append(Data(trailerString.utf8))

    return buffer
  }

  // MARK: - Testler

  /// a) Elle kurulan fixture'ın geçerliliği: qpdf ile okunabiliyor (PDFStructureCheck.isSound)
  /// ve PDFFileInfo TrimBox'ı başarıyla tespit ediyor.
  func testHandBuiltFixtureIsValid() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"), "qpdf binary could not be found")
    let dir = try makeTempDirectory()
    let fixtureURL = dir.appendingPathComponent("fixture.pdf")
    try Self.makeHandBuiltFixtureData().write(to: fixtureURL)

    let info = PDFFileInfo.inspect(fixtureURL)
    XCTAssertNotNil(info.trimBox, "Fixture must declare a valid TrimBox")
    if let trim = info.trimBox {
      XCTAssertEqual(trim.origin.x, 20, accuracy: 0.5)
      XCTAssertEqual(trim.origin.y, 20, accuracy: 0.5)
      XCTAssertEqual(trim.width, 160, accuracy: 0.5)
      XCTAssertEqual(trim.height, 260, accuracy: 0.5)
    }

    let check = try await PDFStructureCheck.inspect(fixtureURL, qpdf: qpdf)
    XCTAssertTrue(check.isSound, "Hand-built fixture must have sound structure: \(check.summary)")
    XCTAssertEqual(check.brokenOffsets, 0)
    XCTAssertTrue(check.errors.isEmpty, "qpdf --check reported errors: \(check.errors)")
  }

  /// b) Kayıpsız kesim envanteri korur: QPDFTrimEngine ile kesince PDFContentInventory farkı
  /// BOŞ olmalı (/DeviceGray renk uzayı ve XMP akışı korunmalı).
  func testLosslessTrimPreservesInventory() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"), "qpdf binary could not be found")
    let dir = try makeTempDirectory()
    let fixtureURL = dir.appendingPathComponent("fixture.pdf")
    try Self.makeHandBuiltFixtureData().write(to: fixtureURL)

    let outputURL = dir.appendingPathComponent("fixture_lossless.pdf")
    let engine = QPDFTrimEngine(executable: qpdf)
    try await engine.trim(input: fixtureURL, output: outputURL) { _ in }

    let before = try await PDFContentInventory.read(fixtureURL, qpdf: qpdf)
    let after = try await PDFContentInventory.read(outputURL, qpdf: qpdf)

    XCTAssertEqual(before.imageCount, 1, "Source must contain exactly 1 image")
    XCTAssertEqual(before.colorSpaces["/DeviceGray"], 1, "Source image color space must be /DeviceGray")
    XCTAssertEqual(before.metadataStreams, 1, "Source must contain 1 XMP metadata stream")

    let diffs = after.differences(from: before)
    XCTAssertEqual(diffs, [], "Lossless trim must preserve content inventory: \(diffs)")
    XCTAssertEqual(after.colorSpaces["/DeviceGray"], 1, "Lossless trim must keep /DeviceGray color space")
    XCTAssertEqual(after.metadataStreams, 1, "Lossless trim must keep XMP metadata stream")
  }

  /// d) TAM BORU HATTI, gerçek dünyaya benzer dosyayla: `TrimOperation` varsayılan kipte bu
  /// fixture'ı kesebiliyor ve dört kapının hepsinden geçiyor. (Diğer testler motorları doğrudan
  /// çağırıyor; bu test kapıların yanlış alarm vermediğini de gösteriyor.)
  func testTrimOperationSucceedsOnTheHandBuiltFixture() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"), "qpdf binary could not be found")
    let dir = try makeTempDirectory()
    let fixtureURL = dir.appendingPathComponent("fixture.pdf")
    try Self.makeHandBuiltFixtureData().write(to: fixtureURL)

    let outcome = try await TrimOperation().run(
      file: PDFFileInfo.inspect(fixtureURL),
      context: OperationContext(
        outputDirectory: dir,
        options: [TrimOperation.outsideOptionID: TrimOperation.keepOutside])
    ) { _ in }
    guard case .produced(let urls, _) = outcome, let output = urls.first else {
      return XCTFail("kesim çıktı üretmedi: \(outcome)")
    }

    let before = try await PDFContentInventory.read(fixtureURL, qpdf: qpdf)
    let after = try await PDFContentInventory.read(output, qpdf: qpdf)
    XCTAssertEqual(after.differences(from: before), [])
    let page = try XCTUnwrap(CGPDFDocument(output as CFURL)?.page(at: 1))
    XCTAssertEqual(page.getBoxRect(.mediaBox).width, 160, accuracy: 0.5)
    XCTAssertEqual(page.getBoxRect(.mediaBox).height, 260, accuracy: 0.5)
  }

  /// c) Yeniden çizme envanteri bozar: CoreGraphicsTrimEngine ile kesince
  /// PDFContentInventory.differences(from:) BOŞ OLMAMALI.
  func testRedrawingChangesTheInventory() async throws {
    let qpdf = try XCTUnwrap(EngineLocator.find("qpdf"), "qpdf binary could not be found")
    let dir = try makeTempDirectory()
    let fixtureURL = dir.appendingPathComponent("fixture.pdf")
    try Self.makeHandBuiltFixtureData().write(to: fixtureURL)

    let outputURL = dir.appendingPathComponent("fixture_redrawn.pdf")
    let engine = CoreGraphicsTrimEngine()
    try await engine.trim(input: fixtureURL, output: outputURL) { _ in }

    let before = try await PDFContentInventory.read(fixtureURL, qpdf: qpdf)
    let after = try await PDFContentInventory.read(outputURL, qpdf: qpdf)
    let diffs = after.differences(from: before)

    // Farkın SADECE var olması yetmez, DOĞRU hasar sınıfı olmalı — yoksa test bir gün alakasız
    // bir sebeple yeşil kalıp fixture'ın hasarı üretmeyi bıraktığını gizler. Beklenen üç fark,
    // gerçek matbaa dosyalarında ölçülenlerin birebir küçük ölçekli karşılığı.
    XCTAssertTrue(
      diffs.contains { $0.contains("/ICCBased") },
      "gri JPEG ICC tabanlı uzaya yeniden etiketlenmedi — fixture hasarı üretmiyor: \(diffs)")
    XCTAssertTrue(
      diffs.contains { $0.contains("metadata") }, "XMP üstverisi kaybı görünmüyor: \(diffs)")
    XCTAssertTrue(
      diffs.contains { $0.contains("version lowered") }, "sürüm düşmesi görünmüyor: \(diffs)")
    XCTAssertEqual(after.colorSpaces["/DeviceGray"] ?? 0, 0)
  }
}
