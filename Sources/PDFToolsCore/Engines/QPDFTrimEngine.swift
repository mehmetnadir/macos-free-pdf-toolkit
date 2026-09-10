import CoreGraphics
import Foundation

/// KAYIPSIZ kesim motoru: yalnızca sayfa sözlüğündeki kutuları (`/MediaBox`, `/CropBox`) TrimBox'a
/// çeker, dosyanın geri kalanına DOKUNMAZ. Sayfa içerik akışları, gömülü görüntüler, fontlar, renk
/// profilleri, açıklamalar, yer imleri ve XMP üstverisi orijinal baytlarıyla geçer — motor hiçbir
/// şeyi yeniden çizmez, yeniden kodlamaz, renk dönüşümü uygulamaz.
///
/// NEDEN VARSAYILAN OLDU (saha arızası + ölçüm, 2026-09-10). Önceki varsayılan
/// `CoreGraphicsTrimEngine` sayfayı yeniden ÇİZİYOR, yani PDF'i baştan yazıyor. Gerçek üç matbaa
/// dosyasında ölçülen bedel:
///   · xref tablosunda 64 / 5 / 31 nesne "offset 0" ile kaydedildi (bozuk çapraz başvuru).
///     Toleranslı okuyucular (Preview, qpdf) onarıp açıyor; KATI okuyucular açmıyor —
///     kullanıcının Ghostscript tabanlı sistemi dosyayı reddetti:
///     "Rebuild failed: Dictionary key 16 is not a name."
///   · PDF sürümü 1.4/1.6 → 1.3'e DÜŞÜRÜLDÜ (saydamlık düzleştirildi).
///   · 56 görüntünün renk uzayı `/DeviceGray`den ICC tabanlı bir uzaya çevrildi → gözle görülür
///     ton/çizgi kayması (piksellerin %2,05'i farklı, en büyük fark 250/255).
///   · Belgedeki 60 XMP üstveri akışının tamamı silindi.
///   · Dosya %37 büyüdü.
/// Bu motorun çıktısı ise kaynakla PİKSEL BİREBİR aynı (gs ile 150 dpi render, max fark 0/255) ve
/// `qpdf --check` sıfır yapısal uyarı veriyor. `CoreGraphicsTrimEngine`/`GhostscriptEngine`
/// yalnızca kullanıcı kesim çizgisi dışındaki içeriğin GERÇEKTEN silinmesini istediğinde
/// (`TrimOperation` "remove" kipi) devreye giriyor.
///
/// SINIRI AÇIKÇA SÖYLENİR: bu motor sayfayı küçültür, kesim payındaki içeriği dosyadan SİLMEZ —
/// içerik akışlarında kalır, ama artık sayfanın parçası değildir (hiçbir uyumlu okuyucu/RIP
/// göstermez). Silme isteniyorsa "remove" kipi kullanılır ve bedeli kullanıcıya bildirilir.
public struct QPDFTrimEngine: TrimEngine {
  public let name = "qpdf"
  public let executable: URL

  public init(executable: URL) {
    self.executable = executable
  }

  public func trim(
    input: URL, output: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    progress(0)
    // Hedef kutular CoreGraphics'ten okunuyor, qpdf JSON'undan DEĞİL. Gerekçe: `/TrimBox`
    // sayfa ağacında miras alınmış ya da alışılmadık yerde tanımlanmış olabilir; CG kutu
    // çözümlemesini (yokluğunda MediaBox'a düşme dahil) kendisi yapıyor. Ayrıca `PDFFileInfo`
    // ve `TrimVerification` de AYNI kaynağı okuyor — motorun yazdığı kutu ile kapının beklediği
    // kutu böylece yapısal olarak aynı yerden geliyor, iki ayrı yorum arasında sapma olamıyor.
    let targets = try Self.targetBoxes(of: input)
    let ids = try await pageObjectIDs(of: input)
    guard ids.count == targets.count else {
      throw EngineError.failed(
        status: -1,
        message:
          "qpdf reports \(ids.count) pages, the PDF reader reports \(targets.count) — file not touched"
      )
    }
    progress(0.2)

    let (header, objects) = try await pageObjects(of: input, ids: ids)
    progress(0.5)

    var changed: [String: Any] = [:]
    for (index, id) in ids.enumerated() {
      guard let box = targets[index] else { continue }
      let objectKey = "obj:\(id)"
      guard let entry = objects[objectKey] as? [String: Any],
        var page = entry["value"] as? [String: Any]
      else {
        throw EngineError.failed(
          status: -1,
          message: "qpdf did not return page \(index + 1) as a dictionary — file not touched")
      }
      // KRİTİK (ölçüldü 2026-09-10): `--update-from-json` nesneyi BİRLEŞTİRMEZ, TAMAMEN EZER.
      // Yalnız kutuları içeren bir sözlük gönderildiğinde sayfa BOŞ KALDI (`/Type`, `/Contents`,
      // `/Resources` dahil her anahtar silindi) ve dosya hâlâ "geçerli PDF" olarak açıldı — tam
      // olarak sessiz bozulma. Bu yüzden sözlüğün TAMAMI geri yazılır, sadece kutular değişir.
      page["/MediaBox"] = Self.jsonBox(box)
      page["/CropBox"] = Self.jsonBox(box)
      // Kesim payı artık YOK: kalan kutular yanıltıcı olurdu — `PDFFileInfo.hasBleed` yeniden
      // `true` döner, arayüz "kesim payı var" der ve kullanıcı aynı işlemi ikinci kez uygular.
      for boxKey in ["/TrimBox", "/BleedBox", "/ArtBox"] {
        page.removeValue(forKey: boxKey)
      }
      changed[objectKey] = ["value": page]
    }
    progress(0.7)

    let update: [String: Any] = ["qpdf": [header, changed]]
    let jsonURL = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.lastPathComponent).qpdf-update.json")
    let fm = FileManager.default
    try? fm.removeItem(at: jsonURL)
    try JSONSerialization.data(withJSONObject: update).write(to: jsonURL)
    defer { try? fm.removeItem(at: jsonURL) }

    let write = try await ProcessRunner.run(
      executable, arguments: [input.path, "--update-from-json=\(jsonURL.path)", output.path])
    try Self.expectSuccess(write, doing: "trim")
    progress(1)
  }

  /// Her sayfanın hedef kutusu; kesilecek bir kutusu olmayan sayfa için `nil` (o sayfa hiç
  /// değiştirilmez — kesim payı yalnız bazı sayfalarda olan dosyalar bu sayede bozulmuyor).
  static func targetBoxes(of input: URL) throws -> [CGRect?] {
    guard let document = CGPDFDocument(input as CFURL), document.isUnlocked else {
      throw EngineError.failed(
        status: -1, message: "PDF could not be opened: \(input.lastPathComponent)")
    }
    let total = document.numberOfPages
    guard total > 0 else {
      throw EngineError.failed(status: -1, message: "PDF has no pages: \(input.lastPathComponent)")
    }
    return (1...total).map { index in
      guard let page = document.page(at: index) else { return nil }
      let trim = page.getBoxRect(.trimBox)
      let media = page.getBoxRect(.mediaBox)
      return Self.boxesDiffer(trim, media) ? trim : nil
    }
  }

  /// `PDFFileInfo.boxToleranceMin` ile aynı eşik; o `private` olduğu için burada tekrar tanımlı.
  /// Değerin AYNI kalması şart: farklı eşikler "kesim payı var" (PDFFileInfo) ile "kesecek bir şey
  /// yok" (motor) arasında sessiz bir çelişki üretirdi.
  static let boxTolerance: CGFloat = 0.5

  static func boxesDiffer(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) >= boxTolerance || abs(a.minY - b.minY) >= boxTolerance
      || abs(a.maxX - b.maxX) >= boxTolerance || abs(a.maxY - b.maxY) >= boxTolerance
  }

  static func jsonBox(_ rect: CGRect) -> [Double] {
    [Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY)]
  }

  private func pageObjectIDs(of input: URL) async throws -> [String] {
    let result = try await ProcessRunner.run(
      executable, arguments: ["--json=latest", "--json-key=pages", input.path])
    try Self.expectSuccess(result, doing: "read the page list")
    guard let data = result.stdout.data(using: .utf8),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pages = root["pages"] as? [[String: Any]]
    else {
      throw EngineError.failed(status: result.status, message: "qpdf page list could not be read")
    }
    return try pages.map { page in
      guard let object = page["object"] as? String else {
        throw EngineError.failed(status: -1, message: "qpdf page list has no object id")
      }
      return object
    }
  }

  /// Yalnız SAYFA nesnelerini ister (`--json-object=...`): tüm belgeyi JSON'a çevirmek büyük
  /// dosyalarda gereksiz yüzlerce megabayt üretirdi. `--json-stream-data=none` akış içeriğini
  /// dışarıda bırakır — akışlar yazma sırasında orijinal dosyadan kopyalanıyor.
  private func pageObjects(of input: URL, ids: [String]) async throws -> (
    header: [String: Any], objects: [String: Any]
  ) {
    var arguments = ["--json=latest", "--json-key=qpdf", "--json-stream-data=none"]
    arguments += ids.map { "--json-object=\($0)" }
    arguments.append(input.path)
    let result = try await ProcessRunner.run(executable, arguments: arguments)
    try Self.expectSuccess(result, doing: "read the page dictionaries")
    guard let data = result.stdout.data(using: .utf8),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let container = root["qpdf"] as? [Any], container.count >= 2,
      let header = container[0] as? [String: Any],
      let objects = container[1] as? [String: Any]
    else {
      throw EngineError.failed(
        status: result.status, message: "qpdf object listing could not be read")
    }
    return (header, objects)
  }

  /// qpdf'te çıkış kodu `3` = "uyarılarla başarılı" (bkz. `.claude/CLAUDE.md`) — hata değil.
  static func expectSuccess(_ result: ProcessResult, doing action: String) throws {
    guard result.status != 0 && result.status != 3 else { return }
    let message = result.stderr.isEmpty ? result.stdout : result.stderr
    throw EngineError.failed(
      status: result.status,
      message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "qpdf could not \(action) (code \(result.status))" : message)
  }
}
