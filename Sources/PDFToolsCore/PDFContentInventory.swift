import Foundation

/// Bir PDF'in İÇERİK ENVANTERİ: kaç görüntü, hangi renk uzaylarında, kaç gömülü font, kaç XMP
/// üstveri akışı, hangi PDF sürümü. Sayfa GÖRÜNÜMÜNE bakmaz — dosyanın neyi TAŞIDIĞINA bakar.
///
/// NEDEN VAR (ölçülmüş körlük, 2026-09-10). Kesim çıktısının kaynağa sadık olup olmadığını piksel
/// karşılaştırmasıyla ölçmek YETMİYOR, çünkü karşılaştırmayı yapan renderer (CoreGraphics) hasarı
/// veren renderer'ın kendisi: gri JPEG'leri ICC tabanlı bir renk uzayına yeniden etiketlediğinde
/// kendi çıktısını yine "aynı" görüyor. Bağımsız bir renderer (gs) ile bakıldığında aynı sayfada
/// piksellerin %2,05'i farklıydı ve en büyük fark 250/255'ti. Yani ölçüm aracı, tam da ölçmesi
/// gereken hasar sınıfına kör.
///
/// Bu envanter o boşluğu kapatıyor ve ucuz: tek `qpdf --json` çağrısı, akış içeriği okunmadan
/// (18 MB / 130 sayfa dosyada ölçülen maliyet ~0,3 sn). Gerçek ölçümde yeniden çizen motorun
/// çıktısı şunu gösteriyordu: 86 `/DeviceGray` görüntünün 57'si `/ICCBased`e dönmüş, 7 XMP akışı
/// SIFIRLANMIŞ, gömülü font sayısı 23'ten 125'e çıkmış (her sayfaya kopyalanmış), sürüm 1.4'ten
/// 1.3'e DÜŞMÜŞ. Hiçbiri piksel karşılaştırmasında görünmüyordu.
public struct PDFContentInventory: Sendable, Equatable {
  public let pdfVersion: String
  public let imageCount: Int
  /// Renk uzayı adı → o uzayda kaç görüntü. Dolaylı başvurular BİR seviye çözülür (`/ICCBased`,
  /// `/Indexed`, `/Separation` gibi aile adı alınır) — nesne numaraları dosya yeniden yazılınca
  /// değişebildiği için ham başvuru dizgesi karşılaştırmaya UYGUN DEĞİL.
  public let colorSpaces: [String: Int]
  public let metadataStreams: Int
  public let embeddedFonts: Int
  public let annotations: Int

  /// İki envanter arasındaki MADDİ farklar, kullanıcıya gösterilebilir cümleler olarak.
  /// Boş liste = içerik korunmuş.
  public func differences(from source: PDFContentInventory) -> [String] {
    var result: [String] = []
    if imageCount != source.imageCount {
      result.append("images \(source.imageCount) → \(imageCount)")
    }
    if colorSpaces != source.colorSpaces {
      let changed = Self.colorSpaceSummary(from: source.colorSpaces, to: colorSpaces)
      if !changed.isEmpty { result.append("image colour spaces changed (\(changed))") }
    }
    if metadataStreams < source.metadataStreams {
      result.append("\(source.metadataStreams - metadataStreams) metadata streams dropped")
    }
    if embeddedFonts < source.embeddedFonts {
      result.append("\(source.embeddedFonts - embeddedFonts) embedded fonts dropped")
    }
    if annotations < source.annotations {
      result.append("\(source.annotations - annotations) annotations dropped")
    }
    if Self.versionValue(pdfVersion) < Self.versionValue(source.pdfVersion) {
      result.append("PDF version lowered \(source.pdfVersion) → \(pdfVersion)")
    }
    return result
  }

  static func colorSpaceSummary(from source: [String: Int], to output: [String: Int]) -> String {
    let names = Set(source.keys).union(output.keys).sorted()
    return names.compactMap { name -> String? in
      let before = source[name] ?? 0
      let after = output[name] ?? 0
      guard before != after else { return nil }
      return "\(name) \(before)→\(after)"
    }.joined(separator: ", ")
  }

  static func versionValue(_ raw: String) -> Double { Double(raw) ?? 0 }

  /// `qpdf --json` ile okur. Akış içeriği İSTENMEZ (`--json-stream-data=none`): envanter için
  /// sözlükler yeterli, akışları taşımak büyük dosyalarda yüzlerce megabayt üretirdi.
  public static func read(_ url: URL, qpdf: URL) async throws -> PDFContentInventory {
    let result = try await ProcessRunner.run(
      qpdf, arguments: ["--json=latest", "--json-key=qpdf", "--json-stream-data=none", url.path])
    guard result.status == 0 || result.status == 3,
      let data = result.stdout.data(using: .utf8),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let container = root["qpdf"] as? [Any], container.count >= 2,
      let header = container[0] as? [String: Any],
      let objects = container[1] as? [String: Any]
    else {
      throw EngineError.failed(
        status: result.status, message: "PDF inventory could not be read: \(url.lastPathComponent)")
    }
    return parse(header: header, objects: objects)
  }

  /// Ayrıştırma alt süreçten AYRI: hangi anahtarın neye sayıldığı bu projenin kararı, testte
  /// alt süreç kurmadan doğrulanabilmeli.
  static func parse(header: [String: Any], objects: [String: Any]) -> PDFContentInventory {
    var colorSpaces: [String: Int] = [:]
    var images = 0
    var metadata = 0
    var fonts = 0
    var annotations = 0
    let fontFileKeys = ["/FontFile", "/FontFile2", "/FontFile3"]

    for (_, raw) in objects {
      guard let entry = raw as? [String: Any] else { continue }
      if let value = entry["value"] as? [String: Any] {
        if let annots = value["/Annots"] as? [Any] { annotations += annots.count }
        if fontFileKeys.contains(where: { value[$0] != nil }) { fonts += 1 }
      }
      guard let stream = entry["stream"] as? [String: Any],
        let dictionary = stream["dict"] as? [String: Any]
      else { continue }
      if dictionary["/Type"] as? String == "/Metadata" { metadata += 1 }
      if fontFileKeys.contains(where: { dictionary[$0] != nil }) { fonts += 1 }
      if dictionary["/Subtype"] as? String == "/Image" {
        images += 1
        let name = colorSpaceName(dictionary["/ColorSpace"], objects: objects)
        colorSpaces[name, default: 0] += 1
      }
    }

    return PDFContentInventory(
      pdfVersion: header["pdfversion"] as? String ?? "0",
      imageCount: images, colorSpaces: colorSpaces, metadataStreams: metadata,
      embeddedFonts: fonts, annotations: annotations)
  }

  /// `/DeviceGray` gibi doğrudan adlar olduğu gibi; `"1065 0 R"` gibi dolaylı başvurular bir
  /// seviye çözülüp AİLE adı (`/ICCBased`, `/Indexed`, `/Separation`, `/DeviceN`) alınır.
  static func colorSpaceName(_ raw: Any?, objects: [String: Any]) -> String {
    if let name = raw as? String {
      if name.hasPrefix("/") { return name }
      guard let entry = objects["obj:\(name)"] as? [String: Any] else { return "unresolved" }
      if let array = entry["value"] as? [Any], let first = array.first as? String { return first }
      if let direct = entry["value"] as? String, direct.hasPrefix("/") { return direct }
      return "unresolved"
    }
    if let array = raw as? [Any], let first = array.first as? String { return first }
    return "none"
  }
}
