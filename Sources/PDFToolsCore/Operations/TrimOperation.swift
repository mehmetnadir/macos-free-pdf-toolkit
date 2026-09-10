import Foundation

/// Kesim payını (baskı taşma payı / bleed) atar: her sayfayı kesim çizgisine (`/TrimBox`)
/// küçültür. Çıktı: `<ad>_trimmed.pdf` (kaynağın yanına ya da seçilen klasöre).
///
/// İKİ KİP (bkz. `options`), 2026-09-10'daki saha arızasından sonra ayrıldı:
///   · "keep" (VARSAYILAN, kayıpsız) — yalnız sayfa kutuları değişir, dosyanın yapısına
///     dokunulmaz. Motor: `QPDFTrimEngine`. Kesim payındaki içerik dosyada KALIR ama artık
///     hiçbir sayfanın parçası değildir.
///   · "remove" — kesim çizgisi dışındaki içerik gerçekten silinir; bunun için her sayfa YENİDEN
///     ÇİZİLİR (motor: gs ya da CoreGraphics). Bedeli var: renk/çizgi kayması, üstveri kaybı,
///     sürüm düşmesi. Ölçümler `QPDFTrimEngine.swift` dosya üstünde.
///
/// Neden varsayılan değişti: eski varsayılan (yeniden çizen motor) gerçek matbaa dosyalarında
/// xref'i kırık çıktı üretiyordu — Preview açıyordu, bizim eski kapımız da "temiz" diyordu, ama
/// kullanıcının Ghostscript tabanlı sistemi dosyayı reddetti ("Rebuild failed: Dictionary key 16
/// is not a name"). Kullanıcı ayrıca renk/çizgi sınırlarındaki kaymayı GÖZLE fark etti; ölçüm onu
/// doğruladı (piksellerin %2,05'i farklı, en büyük fark 250/255 — ortalama fark 0,02 olduğu için
/// önceki ölçüm bunu görmemişti).
public struct TrimOperation: PDFOperation {
  public static let identifier = "trim"
  public let id = TrimOperation.identifier
  public let title = "Trim Bleed"
  public let subtitle = "Resizes every page down to the trim line, so the printer's bleed margin "
    + "is gone"
  public let systemImage = "crop"
  public let actionTitle = "Trim Bleed"
  public let outputSuffix = "_trimmed"
  public var outputSuffixes: [String] { [outputSuffix] }

  public static let outsideOptionID = "outsideContent"
  public static let keepOutside = "keep"
  public static let removeOutside = "remove"

  public init() {}

  public var options: [OperationOption] {
    [
      OperationOption(
        id: Self.outsideOptionID,
        label: "Content outside the trim line",
        choices: [
          (value: Self.keepOutside, label: "Keep it — the file is not rewritten"),
          (value: Self.removeOutside, label: "Delete it — every page is redrawn"),
        ],
        defaultValue: Self.keepOutside)
    ]
  }

  /// Kesim payı OLAN dosya sayısına bakar. Motor kontrolü YOK: kayıpsız kesme motoru qpdf pakette
  /// gelir. Sıra bilerek BÖYLE: kesim payı hiç yoksa "No bleed margin found" demek daha doğru.
  public func applicability(for files: [PDFFileInfo]) -> OperationApplicability {
    guard !files.isEmpty else { return .notApplicable(reason: "Add a PDF first") }
    let bleedCount = files.filter(\.hasBleed).count
    guard bleedCount > 0 else { return .notApplicable(reason: "No bleed margin found") }
    return .applicable(fileCount: bleedCount)
  }

  public func run(
    file: PDFFileInfo, context: OperationContext,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> OperationOutcome {
    switch file.lockState {
    case .unreadable:
      throw OperationError.unreadable
    case .passwordRequired:
      // Şifre çözme bu işlemin kapsamında değil (Kilit Aç'ın işi); kullanıcı önce onu çalıştırmalı.
      throw OperationError.passwordRequired
    case .restricted, .none:
      break
    }

    guard file.trimBox != nil else {
      return .skipped(reason: "No bleed margin found")
    }

    let mode = context.options[Self.outsideOptionID] ?? Self.keepOutside
    let qpdf = EngineLocator.find("qpdf")
    let annotationCount = PDFAnnotations.count(in: file.url)

    let engine: any TrimEngine
    var annotationsWillBeLost = false
    switch Self.engineChoice(
      mode: mode, annotationCount: annotationCount, qpdf: qpdf,
      ghostscript: EngineLocator.ghostscript())
    {
    case .lossless(let binary):
      engine = QPDFTrimEngine(executable: binary)
    case .ghostscript(let binary):
      engine = GhostscriptEngine(executable: binary)
    case .coreGraphics:
      engine = CoreGraphicsTrimEngine()
      // Açıklama var ama gs yok: iş yine yapılır, ancak kaybın SÖYLENMESİ şart — sessizce
      // bağlantıları silmek, kullanıcının aylar sonra fark edeceği bir hasardır.
      annotationsWillBeLost = annotationCount > 0
    case .qpdfMissing:
      throw OperationError.engineMissing(
        "qpdf is missing from this build — reinstall the app, or run packaging/build-engines.sh")
    }

    let output = OutputNaming.uniqueURL(for: file.url, suffix: outputSuffix, in: context.outputDirectory)
    // Motorlar çıktı adında uzantı bekler; diğer işlemlerle tutarlı gizli-ama-.pdf-uzantılı ad.
    let partial = output.deletingLastPathComponent()
      .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.pdf")
    let fm = FileManager.default
    try? fm.removeItem(at: partial)

    do {
      try await engine.trim(input: file.url, output: partial, progress: progress)
    } catch is CancellationError {
      try? fm.removeItem(at: partial)
      throw CancellationError()
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    var notes: [String] = []

    // Sayfaları yeniden çizen motorların ÇIKTISI YAPISAL OLARAK BOZUK olabiliyor (ölçüldü:
    // CoreGraphics çıktısında 64/5/31 nesne "offset 0" ile kaydedildi). qpdf'ten geçirmek bunu
    // onarıyor; kip zaten dosyayı yeniden yazdığı için ek bir kayıp getirmiyor.
    if mode == Self.removeOutside, let qpdf {
      try? await PDFStructureCheck.repair(partial, qpdf: qpdf)
    }

    do {
      try await verify(source: file.url, output: partial, mode: mode, qpdf: qpdf, notes: &notes)
    } catch {
      try? fm.removeItem(at: partial)
      throw error
    }

    try fm.moveItem(at: partial, to: output)

    if !PDFFileInfo.trimBoxIsConsistent(output) {
      notes.append("bleed margin is inconsistent across pages")
    }
    if annotationsWillBeLost {
      notes.append(
        "\(annotationCount) links or form fields could not be kept — install Ghostscript to "
          + "preserve them")
    }
    if mode == Self.keepOutside {
      notes.append(
        "pages were only resized — the bleed content is no longer part of any page but stays "
          + "inside the file")
    }
    return .produced(urls: [output], note: notes.isEmpty ? nil : notes.joined(separator: " · "))
  }

  /// Hangi kipte hangi motor. SAF ve testle çivili: bu projenin en pahalı dersi motor seçimiydi
  /// (varsayılan yeniden-çizen motor, kullanıcıya bozuk dosya teslim etti). İki kural asla
  /// esnemez — (1) kayıpsız kip ASLA yeniden yazan bir motora düşmez, qpdf yoksa hata verir;
  /// (2) tanınmayan bir kip değeri kayıpsız kabul edilir (yanlış yazım hasara yol açamaz).
  enum EngineChoice: Equatable {
    case lossless(URL)
    case ghostscript(URL)
    case coreGraphics
    case qpdfMissing
  }

  static func engineChoice(
    mode: String, annotationCount: Int, qpdf: URL?, ghostscript: URL?
  ) -> EngineChoice {
    guard mode == removeOutside else {
      guard let qpdf else { return .qpdfMissing }
      return .lossless(qpdf)
    }
    // Açıklaması olan dosyada gs tercih edilir: sayfayı yeniden çizen CoreGraphics bağlantı ve
    // form alanlarını tamamen kaybediyor (24/24 kayıp ölçüldü, 2026-09-09). Açıklama yoksa
    // CoreGraphics daha sadık çiziyor ve kurulum gerektirmiyor.
    if annotationCount > 0, let ghostscript { return .ghostscript(ghostscript) }
    return .coreGraphics
  }

  /// ÜÇ BAĞIMSIZ KAPI. Hiçbiri diğerinin yerine geçmiyor; 2026-09-10'da tek kapının (bant ölçümü)
  /// yeterli olmadığı sahada kanıtlandı — çıktı kesim payını atmış, kutuları doğru, yine de
  /// yapısı kırık ve içeriği kaymış olabiliyordu.
  private func verify(
    source: URL, output: URL, mode: String, qpdf: URL?, notes: inout [String]
  ) async throws {
    // 1) YAPI: xref sağlam mı, katı bir ayrıştırıcı dosyayı açabilir mi.
    if let qpdf {
      let structure = try await PDFStructureCheck.inspect(output, qpdf: qpdf)
      guard structure.isSound else {
        throw OperationError.outputStructureBroken(structure.summary)
      }
    }

    // 2) GEOMETRİ: her sayfanın ölçüsü kaynağın TrimBox'ı kadar mı, kesim payı bildirimi kalktı mı.
    let geometry = TrimVerification.geometry(source: source, output: output)
    guard geometry.isCorrect else {
      throw OperationError.trimGeometryFailed(page: geometry.firstMismatch)
    }

    // 3) ENVANTER: dosya NEYİ TAŞIYOR (görüntü/renk uzayı/font/XMP/sürüm). Piksel karşılaştırması
    // bu hasar sınıfına KÖR (bkz. `PDFContentInventory` gerekçesi) — kayıpsız kipte envanter
    // birebir korunmuş olmalı; yeniden çizen kipte kaçınılmaz olan değişiklikler SÖYLENİR.
    if let qpdf {
      let before = try await PDFContentInventory.read(source, qpdf: qpdf)
      let after = try await PDFContentInventory.read(output, qpdf: qpdf)
      let changes = after.differences(from: before)
      if mode == Self.keepOutside {
        guard changes.isEmpty else {
          throw OperationError.trimContentChanged(changes.joined(separator: " · "))
        }
      } else if !changes.isEmpty {
        notes.append("redrawing changed the file: " + changes.joined(separator: " · "))
      }
    }

    // 4) İÇERİK GÖRÜNÜMÜ: kayıpsız kipte içerik DEĞİŞMEMİŞ olmalı (beklenen fark 0,00). Yeniden çizen kipte
    // fark kaçınılmaz — orada kapı bant ölçümüdür, sadakat ise ÖLÇÜLÜP BİLDİRİLİR (sessizce
    // yutulmaz: kullanıcı renk kaymasını bizden önce görmüştü, bir daha olmasın).
    let fidelity = TrimVerification.fidelity(source: source, output: output)
    if mode == Self.keepOutside {
      guard fidelity.isFaithful else {
        throw OperationError.trimFidelityFailed(percent: fidelity.differingPixelPercent)
      }
    } else {
      let band = TrimVerification.verify(output)
      guard band.verdict != .failed else {
        throw OperationError.trimVerificationFailed(percent: band.residuePercent)
      }
      if band.verdict == .partial {
        notes.append("bleed removed — a faint trace remains along the edges")
      }
      if !fidelity.isFaithful {
        let percent = String(format: "%.2f", fidelity.differingPixelPercent)
        notes.append(
          "pages were redrawn — \(percent)% of the rendered pixels differ from the original")
      }
    }
  }
}
