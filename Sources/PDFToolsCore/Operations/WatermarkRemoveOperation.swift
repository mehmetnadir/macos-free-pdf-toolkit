import CoreGraphics
import Foundation

/// Bu işleme özgü hata durumları. `OperationError`'a EKLENMEDİ (o dosyaya dokunmak bu turun
/// kısıtları dışında) — kendi `Error` tipini fırlatmak `PDFOperation.run`'ın imzasıyla zaten
/// uyumlu (yalnızca `throws`, belirli bir tipe bağlı değil).
enum WatermarkRemoveError: Error, LocalizedError, Equatable {
  /// qpdf'in JSON çıktısı beklenen şemada değildi (sürüm farkı, bozuk dosya vb.).
  case malformedQPDFOutput
  /// Doğrulama gate'i (bkz. `WatermarkRemoveVerification`) çıktıyı reddetti.
  case verificationFailed(reason: String)

  var errorDescription: String? {
    switch self {
    case .malformedQPDFOutput: return "Could not parse qpdf's JSON output"
    case .verificationFailed(let reason):
      return "Watermark removal could not be verified — \(reason)"
    }
  }
}

/// Bir Form XObject adayı hakkında toplanan bilgi. `WatermarkRemoveOperation.candidates(in:)`
/// bunları üretir; arayüz kullanıcıya "144 sayfanın 143'ünde bulundu: '…'" diye gösterip
/// onaylatabilir (bkz. `.claude/docs/yol-haritasi-2026-09.md` §1.4 UX akışı).
public struct WatermarkCandidate: Sendable, Equatable {
  /// qpdf gösterimiyle tam nesne referansı, örn. `"1507 0 R"`. `--update-from-json` JSON
  /// anahtarını (`"obj:1507 0 R"`) oluşturmak için birebir bu string kullanılır.
  public let objectReference: String
  /// Yalnız nesne numarası, örn. `"1507"` — `--json-object=` argümanı bunu bekler.
  public let objectID: String
  /// Bu nesnenin kullanıldığı FARKLI sayfa sayısı.
  public let pageCount: Int
  /// Belgedeki toplam sayfa sayısı.
  public let totalPageCount: Int
  /// İçerik akışından (`Tj`/`TJ` dizileri) ayıklanan görünür metin. Taranmış/salt-vektör
  /// (metinsiz) bir şablonda boş olabilir — bu durumda metin yerine BBox/konum gösterilmeli.
  public let extractedText: String
  /// Form XObject'in KENDİ BBox'ı (form koordinat uzayında). Çoğu tam-sayfa filigran şablonu
  /// kimlik `/Matrix` ve kimlik yerleştirme (`cm`) ile çağrıldığından bu, pratikte sayfa
  /// uzayındaki görünür bölgeyle örtüşür (bkz. `WatermarkRemoveVerification` üstündeki varsayım
  /// notu — farklı yerleştirilmiş bir filigranda bu kesin olmayabilir).
  public let bbox: CGRect

  public init(
    objectReference: String, objectID: String, pageCount: Int, totalPageCount: Int,
    extractedText: String, bbox: CGRect
  ) {
    self.objectReference = objectReference
    self.objectID = objectID
    self.pageCount = pageCount
    self.totalPageCount = totalPageCount
    self.extractedText = extractedText
    self.bbox = bbox
  }

  /// Kaç yüzde sayfada bulunduğu — kullanıcıya gösterilecek özet satırın parçası.
  public var coveragePercent: Double {
    totalPageCount == 0 ? 0 : Double(pageCount) / Double(totalPageCount) * 100
  }
}

/// DENEYSEL: sayfalar arası TEKRARLAYAN bir Form XObject'i (tipik "üstüne basılmış" vektör/metin
/// filigranı) bulup akışını boşaltarak kalıcı olarak siler. Motor: qpdf `--json` / `--json-object`
/// (yapı + hedefli akış okuma) ve `--update-from-json` (akışı boşaltıp geri yazma) — Python'suz,
/// pakete zaten gömülü `vendor/bin/qpdf` ile. Yalnızca VEKTÖR/metin tabanlı tekrarlayan nesne
/// kalıbını hedefler; taranmış (raster) filigranlar KAPSAM DIŞI (bkz. yol haritası "v2 gelişmiş
/// mod / inpainting").
///
/// Ölçüm notu (bu turun başında doğrulandı, `.claude/docs/yol-haritasi-2026-09.md` "Python'suz
/// yol henüz kapalı" notunun aksine): `qpdf --json=latest` (yani `--json-output` DEĞİL) ile
/// varsayılan `--decode-level` "generalized"dır — Form XObject içerik akışları (tipik olarak
/// FlateDecode) qpdf tarafından KENDİLİĞİNDEN çözülmüş gelir; yalnızca DCTDecode (JPEG görsel)
/// gibi "lossy" filtreler çözülmeden kalır (görsellerle ilgilenmiyoruz). Bu yüzden Swift
/// `Compression` çerçevesiyle elle flate-çözme YAPILMADI — gereksiz.
///
/// İki geçişli tasarım (büyük kitaplarda maliyeti düşük tutmak için, bkz. ölçüm: 2,1 MB/3
/// sayfalık test dosyasında yapısal geçiş 484 KB iken tam akış-dahil JSON 16,2 MB çıktı):
/// 1. **Yapısal geçiş** — `--json=latest` (akış verisi YOK, varsayılan). Sayfa → nesne eşlemesi
///    ve her nesnenin sözlüğü (BBox, Subtype, Resources/XObject) buradan çıkar.
/// 2. **Hedefli geçiş** — yalnız ADAY nesne(ler) için `--json-object=<id> --json-stream-data=inline`
///    (küçük — tek nesnenin akışı). Aday sayısı tipik olarak tek haneli, tüm kitabın akışlarını
///    hiç yüklemeye gerek yok.
public struct WatermarkRemoveOperation: PDFOperation {
  public static let identifier = "watermarkremove"
  public let id = WatermarkRemoveOperation.identifier
  public let title = "Remove Watermark"
  public let subtitle = "Experimental — removes a watermark object that repeats across all pages"
  public let systemImage = "eraser"
  public let actionTitle = "Remove Watermark"
  public let outputSuffix = "_clean"

  /// Bir Form XObject'in sayfaların EN AZ bu oranında geçmesi "tekrarlayan filigran" adayı
  /// saymak için yeterli sayılır (bkz. yol haritası §1.4 — gerçek kitapta 143/144 ≈ %99,3).
  public static let coverageThreshold: Double = 0.8

  public init() {}

  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    // Bilinçli olarak varsayılanı kullanıyoruz: gerçek tespit (tekrarlayan nesne var mı) qpdf'i
    // ASYNC çalıştırmayı gerektiriyor, bu senkron/hızlı olması gereken `applicability`'nin işi
    // değil (bkz. `TrimOperation` — o da motor kontrolünü `applicability`'ye, gerçek "kesim payı
    // var mı" kontrolünü kendi alanına yapıyor; burada ikisi de `run()` içinde, çünkü ikisi de
    // dosyayı açmayı gerektiriyor).
    files.isEmpty ? .notApplicable(reason: "Add a PDF first") : .applicable(fileCount: files.count)
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable:
      throw OperationError.unreadable
    case .passwordRequired:
      throw OperationError.passwordRequired
    case .restricted, .none:
      break
    }

    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf required (not found in the bundle)")
    }

    progress(0.05)
    let found = try await Self.candidates(in: file.url, qpdfExecutable: qpdf)
    guard !found.isEmpty else {
      return .skipped(reason: "No repeating watermark found")
    }

    let chosen: WatermarkCandidate
    if let requestedRef = context.options["watermarkObject"],
      let match = found.first(where: { $0.objectReference == requestedRef })
    {
      chosen = match
    } else {
      // `found` zaten `pageCount` azalan sırayla geliyor (bkz. `candidates(in:qpdfExecutable:)`).
      chosen = found[0]
    }
    progress(0.3)

    let output = OutputNaming.uniqueURL(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    do {
      try await Self.emptyStream(candidate: chosen, in: file.url, output: partial, qpdfExecutable: qpdf)
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }
    progress(0.7)

    // Kanıt 1: hedef nesnenin akışı çıktıda GERÇEKTEN boşalmış mı — `note`/kutu üstverisine değil,
    // aynı metin çıkarımını çıktı üzerinde TEKRAR çalıştırıp bak (bkz. `TrimVerification`'ın
    // "kutuya değil render'a güven" ilkesinin metin karşılığı, `WatermarkRemoveVerification`).
    do {
      let stillThere = try await !WatermarkRemoveVerification.textReallyRemoved(
        candidate: chosen, output: partial, qpdfExecutable: qpdf)
      guard !stillThere else {
        try? fm.removeItem(at: partial)
        throw WatermarkRemoveError.verificationFailed(
          reason: "the target object's text is still present")
      }
    } catch let error as WatermarkRemoveError {
      throw error
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }
    progress(0.85)

    // Kanıt 2: sayfa sayısı korunmuş + filigran BÖLGESİ DIŞINDA ilk sayfa piksel piksel aynı.
    let pixelResult = WatermarkRemoveVerification.verify(source: file.url, output: partial, candidate: chosen)
    guard pixelResult.verdict != .failed else {
      try? fm.removeItem(at: partial)
      throw WatermarkRemoveError.verificationFailed(reason: pixelResult.reason)
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)

    let textPart = chosen.extractedText.isEmpty ? "" : " '\(chosen.extractedText)'"
    let note =
      "Removed\(textPart), found on \(chosen.pageCount) of \(chosen.totalPageCount) pages"
    return .produced(urls: [output], note: note)
  }

  // MARK: - Aday tespiti (herkese açık API — arayüz onay kartı için kullanır)

  /// `url`'deki PDF'i tarar, sayfaların `Self.coverageThreshold` oranında (≥ %80) tekrarlayan
  /// Form XObject'lerini aday olarak döner. Motor bulunamazsa hata fırlatır.
  public static func candidates(in url: URL) async throws -> [WatermarkCandidate] {
    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf required (not found in the bundle)")
    }
    return try await candidates(in: url, qpdfExecutable: qpdf)
  }

  static func candidates(in url: URL, qpdfExecutable: URL) async throws -> [WatermarkCandidate] {
    let structural = try await runQPDFJSON(qpdfExecutable, arguments: ["--json=latest", url.path])
    guard
      let root = try JSONSerialization.jsonObject(with: structural) as? [String: Any],
      let pages = root["pages"] as? [[String: Any]],
      let qpdfArray = root["qpdf"] as? [Any], qpdfArray.count == 2,
      let objects = qpdfArray[1] as? [String: Any]
    else {
      throw WatermarkRemoveError.malformedQPDFOutput
    }
    let totalPages = pages.count
    guard totalPages > 0 else { return [] }

    func dict(for ref: String) -> [String: Any]? {
      guard let entry = objects["obj:\(ref)"] as? [String: Any] else { return nil }
      if let value = entry["value"] as? [String: Any] { return value }
      if let stream = entry["stream"] as? [String: Any], let d = stream["dict"] as? [String: Any] {
        return d
      }
      return nil
    }

    // BUG DÜZELTMESİ (gerçek kitapla saha ölçümü, bkz. görev notu): bir sözlük DEĞERİ (ör.
    // `/Resources`, `/Resources`'ın kendi `/XObject`'i) DOLAYLI REFERANS olabilir — gömülü bir
    // sözlük yerine `"353 0 R"` gibi bir DİZE gelir; bu, PDF'te tamamen yasal ve YAYGIN bir kalıp
    // (qpdf bunu "çözmez", olduğu gibi yansıtır). İlk sürüm bunu `as? [String: Any]` ile doğrudan
    // cast'lemeye çalışıyordu; dize geldiğinde cast SESSİZCE nil dönüyor, sayfa hiç sayılmadan
    // atlanıyordu — gerçek kitapta (592,9 MB / 144 sayfa) HEM `/Resources` HEM içindeki `/XObject`
    // dolaylıydı, bu yüzden `candidates(in:)` sahada HER ZAMAN boş dönüyordu (ölçüldü: 0,06 sn'de
    // 576 KB yapısal JSON'da elle tarama 143/144 buluyor, ama eski kod 0 aday buluyordu).
    func resolveDict(_ raw: Any?) -> [String: Any]? {
      if let embedded = raw as? [String: Any] { return embedded }
      if let ref = raw as? String { return dict(for: ref) }
      return nil
    }

    // Sayfanın `/Resources`'ı sayfada YOKSA (PDF spec §7.7.3.4 miras kuralı — bir sayfa kendi
    // `/Resources`'ını tanımlamayıp `/Pages` ata zincirinden miras alabilir) `/Parent` zincirini
    // tırmanır. Gerçek kitapta gözlenmedi (her sayfa kendi — dolaylı — `/Resources`'ını taşıyor)
    // ama spec'e uymak ucuz; sonsuz döngüye karşı derinlik sınırı var.
    func resources(for pageDict: [String: Any]) -> [String: Any]? {
      var current: [String: Any]? = pageDict
      var depth = 0
      while let node = current, depth < 32 {
        if let resources = resolveDict(node["/Resources"]) { return resources }
        guard let parentRef = node["/Parent"] as? String else { return nil }
        current = dict(for: parentRef)
        depth += 1
      }
      return nil
    }

    // objectRef -> bu nesnenin kullanıldığı sayfa İNDEKSLERİ (tekrar sayımı için `Set`, aynı
    // sayfada iki farklı isimle (ör. `/Fm0` ve `/Fm5`) aynı nesneye referans olsa bile bir kez
    // sayılır).
    var occurrences: [String: Set<Int>] = [:]
    for (index, page) in pages.enumerated() {
      guard let pageRef = page["object"] as? String, let pageDict = dict(for: pageRef) else { continue }
      guard
        let res = resources(for: pageDict),
        let xobject = resolveDict(res["/XObject"])
      else { continue }
      for value in xobject.values {
        guard let ref = value as? String else { continue }
        occurrences[ref, default: []].insert(index)
      }
    }

    let threshold = Double(totalPages) * coverageThreshold
    var results: [WatermarkCandidate] = []
    for (ref, pageIndices) in occurrences {
      guard Double(pageIndices.count) >= threshold else { continue }
      guard let objDict = dict(for: ref), (objDict["/Subtype"] as? String) == "/Form" else { continue }
      let objectID = ref.split(separator: " ").first.map(String.init) ?? ref
      let snapshot = try await fetchDecodedObject(
        objectID: objectID, url: url, qpdfExecutable: qpdfExecutable)
      results.append(
        WatermarkCandidate(
          objectReference: ref, objectID: objectID, pageCount: pageIndices.count,
          totalPageCount: totalPages, extractedText: snapshot.decodedText,
          bbox: bbox(from: objDict["/BBox"])))
    }
    return results.sorted { $0.pageCount > $1.pageCount }
  }

  // MARK: - Hedefli nesne okuma (yapı + dekode edilmiş akış metni)

  /// Tek bir nesnenin sözlüğü (akış filtresi qpdf tarafından zaten uygulanmış/kaldırılmış hâliyle
  /// — bkz. tip üstü ölçüm notu) + akışından ayıklanan görüntülenebilir metin.
  struct ObjectSnapshot { let dict: [String: Any]; let decodedText: String }

  /// `--json-object=<id> --json-stream-data=inline` ile TEK bir nesneyi hedefli okur. `dict`
  /// buradan gelen hâliyle KULLANILABİLİR durumdadır (data zaten çözülmüş olduğundan `/Filter`
  /// ve `/Length` dict'te YOKTUR) — `emptyStream` bunu doğrudan `--update-from-json` girişine
  /// verir, ayrıca bir "filtreyi temizle" adımına gerek kalmaz (gerçek qpdf denemesiyle
  /// doğrulandı).
  static func fetchDecodedObject(
    objectID: String, url: URL, qpdfExecutable: URL
  ) async throws -> ObjectSnapshot {
    let data = try await runQPDFJSON(
      qpdfExecutable,
      arguments: ["--json=latest", "--json-object=\(objectID)", "--json-stream-data=inline", url.path])
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let qpdfArray = root["qpdf"] as? [Any], qpdfArray.count == 2,
      let objects = qpdfArray[1] as? [String: Any],
      let entry = objects.values.first as? [String: Any],
      let stream = entry["stream"] as? [String: Any],
      let dict = stream["dict"] as? [String: Any],
      let base64 = stream["data"] as? String,
      let raw = Data(base64Encoded: base64)
    else {
      throw WatermarkRemoveError.malformedQPDFOutput
    }
    let content =
      String(data: raw, encoding: .windowsCP1252)
      ?? String(data: raw, encoding: .utf8)
      ?? String(data: raw, encoding: .isoLatin1)
      ?? ""
    return ObjectSnapshot(dict: dict, decodedText: extractDisplayText(from: content))
  }

  /// Adayın akışını qpdf `--update-from-json` ile BOŞALTIR (nesne grafiği/sözlüğü korunur, yalnız
  /// içerik silinir) — Form XObject geçerli kalır ama çağrıldığında hiçbir şey çizmez. Gerçek
  /// deneme ile doğrulandı: minimal `{"qpdf":[{"jsonversion":2},{"obj:N 0 R":{"stream":{"data":"",
  /// "dict":{...}}}}]}` girişi qpdf tarafından kabul ediliyor, yalnızca o nesneyi değiştiriyor,
  /// belgenin geri kalanına (sayfa sayısı dahil) dokunmuyor.
  static func emptyStream(
    candidate: WatermarkCandidate, in inputURL: URL, output: URL, qpdfExecutable: URL
  ) async throws {
    let snapshot = try await fetchDecodedObject(
      objectID: candidate.objectID, url: inputURL, qpdfExecutable: qpdfExecutable)
    let update: [String: Any] = [
      "qpdf": [
        ["jsonversion": 2],
        ["obj:\(candidate.objectReference)": ["stream": ["data": "", "dict": snapshot.dict]]],
      ]
    ]
    let updateData = try JSONSerialization.data(withJSONObject: update)
    let updateFile = output.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).watermarkupdate.json")
    try updateData.write(to: updateFile)
    defer { try? FileManager.default.removeItem(at: updateFile) }

    let result = try await ProcessRunner.run(
      qpdfExecutable,
      arguments: ["--update-from-json=\(updateFile.path)", inputURL.path, output.path])
    guard result.status == 0 || result.status == 3 else {
      throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
    }
  }

  // MARK: - Yardımcılar

  static func runQPDFJSON(_ executable: URL, arguments: [String]) async throws -> Data {
    let result = try await ProcessRunner.run(executable, arguments: arguments)
    guard result.status == 0 || result.status == 3 else {
      throw EngineError.failed(status: result.status, message: result.stderr)
    }
    return Data(result.stdout.utf8)
  }

  static func bbox(from value: Any?) -> CGRect {
    guard let array = value as? [Any], array.count == 4 else { return .zero }
    let nums = array.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
    let x0 = nums[0], y0 = nums[1], x1 = nums[2], y1 = nums[3]
    return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
  }

  /// PDF içerik akışındaki `(...)`  parantez-sınırlı DİZİ değerlerini (literal string operandları
  /// — `Tj`/`TJ`'nin gösterdiği metin budur) ayıklar. Tam bir içerik akışı ayrıştırıcısı DEĞİL:
  /// hangi operatörün çağrıldığına bakmaz, yalnızca her `(...)` bloğunu (iç içe/kaçışlı parantez
  /// dahil) toplar — filigran tespiti için bu kadarı yeterli (bkz. görev notu). Hex dizileri
  /// (`<...>`) ve `TJ` dizisi içindeki sayısal ofsetler bilerek atlanıyor.
  static func extractDisplayText(from content: String) -> String {
    var result = ""
    let chars = Array(content)
    var i = 0
    while i < chars.count {
      guard chars[i] == "(" else {
        i += 1
        continue
      }
      var depth = 1
      i += 1
      var literal = ""
      while i < chars.count, depth > 0 {
        let c = chars[i]
        if c == "\\", i + 1 < chars.count {
          let next = chars[i + 1]
          switch next {
          case "n": literal.append("\n")
          case "r": literal.append("\r")
          case "t": literal.append("\t")
          default: literal.append(next)
          }
          i += 2
          continue
        }
        if c == "(" {
          depth += 1
          literal.append(c)
        } else if c == ")" {
          depth -= 1
          if depth > 0 { literal.append(c) }
        } else {
          literal.append(c)
        }
        i += 1
      }
      if !literal.isEmpty {
        if !result.isEmpty { result += " " }
        result += literal
      }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
