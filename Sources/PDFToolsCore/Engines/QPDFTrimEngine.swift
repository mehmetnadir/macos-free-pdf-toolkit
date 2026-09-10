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
  /// Kesim dışındaki içeriğe ne olacak. İKİSİ DE KAYIPSIZ — fark, içeriğin GÖSTERİLEBİLİR
  /// kalıp kalmadığında.
  public enum Mode: String, Sendable {
    /// Yalnız kutular küçülür. Kesim payındaki içerik dosyada kalır ve kutu tekrar büyütülürse
    /// geri gelir (yani işlem geri alınabilir).
    case boxesOnly
    /// Kutular küçülür VE içerik akışının başına bir kırpma yolu (`re W n`) eklenir, sonuna
    /// eşleşen `Q`. Kesim çizgisi dışında kalan hiçbir şey artık HİÇBİR okuyucuda çizilemez.
    /// Adobe Acrobat'ın Preflight düzeltmeleri ve Enfocus PitStop'un "crop line art" eylemi de
    /// aynı düzeyde (nesne/akış düzeyinde) çalışır — rasterleştirme YOK.
    case clipOutside
  }

  public let name = "qpdf"
  public let executable: URL
  public let mode: Mode

  public init(executable: URL, mode: Mode = .clipOutside) {
    self.executable = executable
    self.mode = mode
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
    let editor = QPDFPageEditor(executable: executable)
    let ids = try await editor.pageObjectIDs(of: input)
    guard ids.count == targets.count else {
      throw EngineError.failed(
        status: -1,
        message:
          "qpdf reports \(ids.count) pages, the PDF reader reports \(targets.count) — file not touched"
      )
    }
    progress(0.2)

    let (header, objects) = try await editor.pageObjects(of: input, ids: ids)
    progress(0.5)

    var changed: [String: Any] = [:]
    // Kırpma akışları PAYLAŞILIR: aynı kutuya sahip sayfalar aynı nesneyi kullanır, kapanış `Q`
    // ise tüm belgede tek nesnedir. 500 sayfalık bir kitapta 1000 yeni nesne yerine 2 nesne.
    var nextObjectID = (header["maxobjectid"] as? Int ?? 0) + 1
    var clipObjects: [String: String] = [:]  // kutu imzası → "N 0 R"
    var closeReference: String?

    for (index, id) in ids.enumerated() {
      guard let box = targets[index] else { continue }
      let objectKey = "obj:\(id)"
      guard var page = QPDFPageEditor.dictionary(for: id, in: objects) else {
        throw EngineError.failed(
          status: -1,
          message: "qpdf did not return page \(index + 1) as a dictionary — file not touched")
      }
      // KRİTİK (ölçüldü 2026-09-10): `--update-from-json` nesneyi BİRLEŞTİRMEZ, TAMAMEN EZER.
      // Yalnız kutuları içeren bir sözlük gönderildiğinde sayfa BOŞ KALDI (`/Type`, `/Contents`,
      // `/Resources` dahil her anahtar silindi) ve dosya hâlâ "geçerli PDF" olarak açıldı — tam
      // olarak sessiz bozulma. Bu yüzden sözlüğün TAMAMI geri yazılır, sadece kutular değişir.
      page["/MediaBox"] = QPDFPageEditor.jsonBox(box)
      page["/CropBox"] = QPDFPageEditor.jsonBox(box)
      // Kesim payı artık YOK: kalan kutular yanıltıcı olurdu — `PDFFileInfo.hasBleed` yeniden
      // `true` döner, arayüz "kesim payı var" der ve kullanıcı aynı işlemi ikinci kez uygular.
      for boxKey in ["/TrimBox", "/BleedBox", "/ArtBox"] {
        page.removeValue(forKey: boxKey)
      }

      if mode == .clipOutside, let contents = Self.contentReferences(page["/Contents"]) {
        let signature = Self.clipProgram(for: box)
        let openReference: String
        if let existing = clipObjects[signature] {
          openReference = existing
        } else {
          openReference = "\(nextObjectID) 0 R"
          nextObjectID += 1
          changed["obj:\(openReference)"] = Self.streamObject(signature)
          clipObjects[signature] = openReference
        }
        if closeReference == nil {
          closeReference = "\(nextObjectID) 0 R"
          nextObjectID += 1
          changed["obj:\(closeReference!)"] = Self.streamObject("Q\n")
        }
        // Sıra: [kırpma] + özgün akışlar + [Q]. Özgün akışların BAYTLARINA dokunulmuyor;
        // sayfanın içerik dizisine iki yeni akış ekleniyor (PDF akışları sırayla birleştirilir).
        page["/Contents"] = [openReference] + contents + [closeReference!]
      }

      changed[objectKey] = ["value": page]
    }
    progress(0.7)

    var updatedHeader = header
    // qpdf yeni nesneleri kabul ediyor (ölçüldü) ama başlıktaki `maxobjectid` gerçeği
    // yansıtmalı — eklenen nesneler bunun ÜSTÜNDE numaralandı.
    updatedHeader["maxobjectid"] = max(header["maxobjectid"] as? Int ?? 0, nextObjectID - 1)
    let update: [String: Any] = ["qpdf": [updatedHeader, changed]]
    try await editor.apply(update: update, to: input, output: output)
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

  /// Sayfanın içerik akışı başvuruları. `/Contents` tek başvuru da olabilir, dizi de; yoksa
  /// (içeriksiz sayfa) `nil` — kırpılacak bir şey yoktur.
  static func contentReferences(_ raw: Any?) -> [String]? {
    if let single = raw as? String, !single.isEmpty { return [single] }
    if let array = raw as? [Any] {
      let references = array.compactMap { $0 as? String }
      return references.isEmpty ? nil : references
    }
    return nil
  }

  /// Kırpma yolu. `re W n` kesişen nesneleri de kırpar (tam dışta kalanlar hiç çizilmez);
  /// `q` ile açılır, sayfanın sonundaki `Q` ile kapanır — dengesiz grafik durumu bırakmıyoruz.
  static func clipProgram(for box: CGRect) -> String {
    let numbers = [box.minX, box.minY, box.width, box.height]
      .map { String(format: "%.5f", $0) }.joined(separator: " ")
    return "q \(numbers) re W n\n"
  }

  /// qpdf JSON'unda bir akış nesnesi. `/Length` veriliyor ama qpdf yine kendisi hesaplıyor
  /// (ölçüldü: akışı Flate ile sıkıştırıp uzunluğu düzeltti) — yanlış uzunluk yazma riski yok.
  static func streamObject(_ program: String) -> [String: Any] {
    let data = Data(program.utf8)
    return ["stream": ["dict": ["/Length": data.count], "data": data.base64EncodedString()]]
  }
}
