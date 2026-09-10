import Foundation

/// qpdf'in JSON güncelleme kipiyle SAYFA SÖZLÜKLERİNİ düzenleme makinesi. Dosyanın geri kalanına
/// dokunmadan (akışlar orijinal baytlarıyla kopyalanır) sayfa anahtarlarını değiştirmenin tek
/// güvenli yolu; `QPDFTrimEngine` (kesim) ve `TrimVerification` (bant ölçümü için kutuyu geçici
/// büyütme) ortak kullanıyor.
///
/// KRİTİK SÖZLEŞME (ölçüldü 2026-09-10): `--update-from-json` bir nesneyi BİRLEŞTİRMEZ, TAMAMEN
/// EZER. Yalnız değişen anahtarları içeren bir sözlük gönderilirse sayfa BOŞALIR (`/Type`,
/// `/Contents` dahil) ve dosya hâlâ "geçerli PDF" olarak açılır — sessiz bozulma. Bu yüzden
/// çağıranlar sözlüğün TAMAMINI geri yazmak zorunda; `pageObjects` tam sözlükleri bu iş için verir.
struct QPDFPageEditor {
  let executable: URL

  /// Belge sırasına göre sayfa nesne kimlikleri ("15744 0 R").
  func pageObjectIDs(of input: URL) async throws -> [String] {
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

  /// Yalnız SAYFA nesneleri (`--json-object=...`) ve akış içeriği OLMADAN
  /// (`--json-stream-data=none`): tüm belgeyi JSON'a çevirmek büyük dosyalarda yüzlerce megabayt
  /// üretirdi; akışlar yazma sırasında orijinal dosyadan kopyalanıyor.
  func pageObjects(of input: URL, ids: [String]) async throws -> (
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

  /// Güncellemeyi geçici bir JSON dosyası üzerinden uygular. JSON, çıktının yanında gizli bir ada
  /// yazılır ve her durumda silinir.
  func apply(update: [String: Any], to input: URL, output: URL) async throws {
    let jsonURL = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.lastPathComponent).qpdf-update.json")
    let fm = FileManager.default
    try? fm.removeItem(at: jsonURL)
    try JSONSerialization.data(withJSONObject: update).write(to: jsonURL)
    defer { try? fm.removeItem(at: jsonURL) }
    let result = try await ProcessRunner.run(
      executable, arguments: [input.path, "--update-from-json=\(jsonURL.path)", output.path])
    try Self.expectSuccess(result, doing: "write the updated PDF")
  }

  /// Sayfa sözlüğünü (tam hâliyle) döner; nesne bulunamazsa `nil`.
  static func dictionary(for id: String, in objects: [String: Any]) -> [String: Any]? {
    (objects["obj:\(id)"] as? [String: Any])?["value"] as? [String: Any]
  }

  static func jsonBox(_ rect: CGRect) -> [Double] {
    [Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY)]
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
