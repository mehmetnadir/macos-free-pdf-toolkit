import Foundation

/// Bir PDF'in sayfalarını TEK geçişte yeniden sıralar, siler ve döndürür. Etkileşimli sayfa seçimi
/// ARAYÜZE ait; bu katman `OperationContext.options` üzerinden hazır bir "sayfa planı" alır
/// (bkz. `PageEditPlan.parse`) ve qpdf ile uygular. Motor: yalnız qpdf — `--pages . <sıra>` ile
/// sırala/sil, `--rotate=<derece>:<çıktı-pozisyonu>` ile döndür.
///
/// ÖNEMLİ (ölçülüp doğrulandı, 2026-09-07 — bkz. scratchpad ölçümü): qpdf'in `--rotate` seçeneği,
/// komut satırındaki KONUMUNDAN bağımsız olarak HER ZAMAN `--pages` seçiminden SONRAKİ (yani ÇIKTI)
/// sayfa numaralamasına göre çalışır — `--pages`'ten ÖNCE yazılsa BİLE. Örnek: `a.pdf --rotate=+90:2
/// --pages . 3,1,2 -- out.pdf` çıktının 2. sayfasını (kaynağın 1. sayfası, sıralamada 2. konuma
/// gelmiş) döndürür — kaynağın kendi 2. sayfasını DEĞİL. Arayüzden gelen döndürme talebi KAYNAK sayfa
/// numarasıyla geldiği için (`PageEditPlan.rotations` sözleşmesi), qpdf'e vermeden önce `plan.order`
/// içindeki ÇIKTI konumuna çeviriyoruz (bkz. `PageEditPlan.qpdfArguments`). Bu sayede tek geçişte
/// (tek qpdf çağrısında) hem sırala/sil hem döndür yapılabiliyor — iki aşamalı geçici dosyaya gerek
/// yok.
///
/// Ayrıca `--rotate=<derece>:...` İŞARETSİZ (mutlak) kullanılır: `+derece` GÖRECELİ olur ve mevcut
/// `/Rotate` değerine EKLENİR; arayüzden gelen değer ise İSTENEN NİHAİ açı olduğundan mutlak doğru
/// olan budur (ölçüldü: mutlak `--rotate=180:1` iki kez art arda uygulansa bile sonuç hep 180 kalıyor
/// — idempotent; `+180` olsaydı ikinci uygulamada 0'a dönerdi).
public struct PageEditOperation: PDFOperation {
  public static let identifier = "pageedit"
  public let id = PageEditOperation.identifier
  public let title = "Organize Pages"
  public let subtitle = "Reorders, rotates, and deletes pages"
  public let systemImage = "square.grid.2x2"
  public let actionTitle = "Apply Pages"
  public let outputSuffix = "_pages"

  /// `OperationContext.options` anahtarı: tutulacak sayfaların 1-tabanlı KAYNAK numaraları, istenen
  /// ÇIKTI sırasında, virgülle (`"3,1,2,5"`). Boşsa/eksikse tüm sayfalar kaynak sırasıyla tutulur.
  public static let pageOrderOptionID = "pageOrder"
  /// `OperationContext.options` anahtarı: KAYNAK sayfa numarası → hedef derece eşlemesi
  /// (`"1:90,4:180,7:270"`). Derece yalnız 0/90/180/270; 0 "döndürme yok" demektir.
  public static let rotationsOptionID = "rotations"

  public init() {}

  /// Listede kaç dosya olursa olsun tek dosyada çalışır (bkz. `AppModel.beginPageEdit`: ilk
  /// bekleyen dosya hedef alınır) — bu yüzden dosya varsa HER ZAMAN `.applicable(1)`, dosya sayısı
  /// önemli değil. Arayüz bu durumda özel bir gerekçe metni gösterir (bkz. `ContentView`).
  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    files.isEmpty ? .notApplicable(reason: "Add a PDF first") : .applicable(fileCount: 1)
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

    let plan = try PageEditPlan.parse(options: context.options, pageCount: file.pageCount)

    guard let qpdf = EngineLocator.find("qpdf") else {
      throw OperationError.engineMissing("qpdf engine not found")
    }

    let output = OutputNaming.uniqueURL(
      for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    progress(0)
    let arguments = plan.qpdfArguments(input: file.url, output: partial)
    do {
      let result = try await ProcessRunner.run(qpdf, arguments: arguments)
      guard result.status == 0 || result.status == 3 else {
        throw EngineError.failed(status: result.status, message: result.stderr + result.stdout)
      }
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }
    progress(0.9)

    // Kanıt: motora güvenme — çıktıyı KENDİMİZ ölçüyoruz (bkz. PageEditVerification yorumu: sıra/
    // silme piksel karşılaştırmasıyla, döndürme ise bağımsızca yeniden okunan `/Rotate` bayrağıyla).
    let verification = PageEditVerification.verify(input: file.url, plan: plan, output: partial)
    guard verification.verdict == .clean else {
      try? fm.removeItem(at: partial)
      throw PageEditError.verificationFailed(verification.message)
    }

    try fm.moveItem(at: partial, to: output)
    progress(1)
    return .produced(urls: [output], note: nil)
  }
}

/// Arayüzden gelen ham `options` sözlüğünden ayrıştırılmış, DOĞRULANMIŞ bir sayfa planı.
public struct PageEditPlan: Sendable, Equatable {
  /// Tutulacak sayfaların KAYNAK (1-tabanlı) numaraları, istenen ÇIKTI sırasında. Bu dizide
  /// bulunmayan kaynak sayfa numaraları SİLİNMİŞ sayılır. Asla boş değildir (bkz. `parse`).
  public let order: [Int]
  /// KAYNAK sayfa numarası → mutlak hedef derece (yalnız 90/180/270). "0" girişleri "döndürme yok"
  /// anlamına geldiği için burada hiç TUTULMAZ — `rotations[n] == nil` "döndürme yok" ile eşdeğerdir.
  public let rotations: [Int: Int]

  private static let validDegrees: Set<Int> = [0, 90, 180, 270]

  public static func parse(options: [String: String], pageCount: Int) throws -> PageEditPlan {
    let order = try parseOrder(options[PageEditOperation.pageOrderOptionID], pageCount: pageCount)
    let rotations = try parseRotations(
      options[PageEditOperation.rotationsOptionID], pageCount: pageCount)
    return PageEditPlan(order: order, rotations: rotations)
  }

  private static func parseOrder(_ raw: String?, pageCount: Int) throws -> [Int] {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
      // "Boş/eksikse tüm sayfalar sırayla" — anahtar hiç yoksa ya da değer tamamen boşsa varsayılan.
      return pageCount > 0 ? Array(1...pageCount) : []
    }
    let tokens =
      raw.split(separator: ",", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    // Değer VERİLMİŞ ama yalnız ayraçlardan oluşuyorsa (ör. ",,," ya da " , ") — bu sıfır sayfa
    // tutmak, yani TÜM SAYFALARI SİLMEK anlamına gelir. Varsayılana (tüm sayfalar) sessizce
    // düşmek yerine burada AÇIKÇA hata veriyoruz: arayüz bir şey göndermeye ÇALIŞMIŞ ama sonuç
    // anlamsız, sessizce "tüm sayfalar" davranışına dönmek gerçek niyeti gizlerdi.
    guard !tokens.isEmpty else { throw PageEditError.emptyResult }
    var seen = Set<Int>()
    var result: [Int] = []
    for token in tokens {
      guard let n = Int(token) else { throw PageEditError.invalidPageToken(token) }
      guard n >= 1, n <= pageCount else { throw PageEditError.pageOutOfRange(n, pageCount) }
      guard seen.insert(n).inserted else { throw PageEditError.duplicatePageNumber(n) }
      result.append(n)
    }
    guard !result.isEmpty else { throw PageEditError.emptyResult }
    return result
  }

  private static func parseRotations(_ raw: String?, pageCount: Int) throws -> [Int: Int] {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [:] }
    let tokens =
      raw.split(separator: ",", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    var seenPages = Set<Int>()
    var result: [Int: Int] = [:]
    for token in tokens {
      let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 2,
        let page = Int(parts[0].trimmingCharacters(in: .whitespaces)),
        let degree = Int(parts[1].trimmingCharacters(in: .whitespaces))
      else { throw PageEditError.invalidRotationToken(token) }
      guard page >= 1, page <= pageCount else {
        throw PageEditError.pageOutOfRange(page, pageCount)
      }
      guard validDegrees.contains(degree) else { throw PageEditError.invalidRotationDegree(degree) }
      guard seenPages.insert(page).inserted else { throw PageEditError.duplicatePageNumber(page) }
      if degree != 0 { result[page] = degree }
    }
    return result
  }

  /// Tek qpdf çağrısının argümanları: `--rotate` (varsa, ÇIKTI pozisyonlarına çevrilmiş, mutlak
  /// derece) + `--pages . <kaynak-sırası>` (sırala + sil). Bkz. `PageEditOperation` tip yorumu:
  /// `--rotate` komut satırı konumundan bağımsız olarak ÇIKTI numaralamasına göre çalıştığı için
  /// çeviri burada yapılıyor.
  func qpdfArguments(input: URL, output: URL) -> [String] {
    var arguments: [String] = [input.path]
    // Derece → [çıktı pozisyonu] grupları. Sıralama yalnız DETERMİNİZM için (testler + ölçülebilir
    // davranış); qpdf'e argüman sırası fonksiyonel olarak fark etmiyor.
    var byDegree: [Int: [Int]] = [:]
    for (sourcePage, degree) in rotations {
      // Sayfa `order`'da yoksa silinmiş demektir — döndürme talebi no-op olur.
      guard let position = order.firstIndex(of: sourcePage) else { continue }
      byDegree[degree, default: []].append(position + 1)
    }
    for degree in byDegree.keys.sorted() {
      let positions = byDegree[degree]!.sorted().map(String.init).joined(separator: ",")
      arguments.append("--rotate=\(degree):\(positions)")
    }
    arguments += ["--pages", ".", order.map(String.init).joined(separator: ","), "--", output.path]
    return arguments
  }
}

public enum PageEditError: Error, LocalizedError, Equatable {
  /// Verilen sayfa numarası 1...toplam aralığının dışında (`verilen`, `toplam sayfa`).
  case pageOutOfRange(Int, Int)
  /// Aynı sayfa numarası planda (sırada ya da döndürmede) birden çok kez geçiyor.
  case duplicatePageNumber(Int)
  /// `pageOrder` içindeki bir parça tam sayı olarak ayrıştırılamadı.
  case invalidPageToken(String)
  /// `rotations` içindeki bir parça `sayfa:derece` biçiminde değil.
  case invalidRotationToken(String)
  /// Derece 0/90/180/270 dışında.
  case invalidRotationDegree(Int)
  /// Plan hiçbir sayfa tutmuyor (tüm sayfaları silmeye eşdeğer).
  case emptyResult
  /// `PageEditVerification` çıktıyı `.failed` işaretledi; çıktı silinir.
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .pageOutOfRange(let page, let total):
      return "Page number \(page) is invalid — the document has \(total) pages"
    case .duplicatePageNumber(let page):
      return "Page \(page) appears more than once in the plan"
    case .invalidPageToken(let token):
      return "'\(token)' is not a valid page number"
    case .invalidRotationToken(let token):
      return "'\(token)' is not a valid rotation entry (expected page:degree)"
    case .invalidRotationDegree(let degree):
      return "Rotation degree \(degree) is invalid — only 0, 90, 180, or 270 are allowed"
    case .emptyResult:
      return "Plan keeps no pages — deleting all pages isn't allowed"
    case .verificationFailed(let detail):
      return "Page edit could not be verified — \(detail) — output deleted"
    }
  }
}
