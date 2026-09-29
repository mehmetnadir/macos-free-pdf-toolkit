import Foundation
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct ProcessResult: Sendable {
  let status: Int32
  let stdout: String
  let stderr: String
}

/// `ProcessRunner.run` bir alt süreci ZAMAN AŞIMI yüzünden kendi sonlandırdığında fırlattığı hata.
/// Motorun kendi çıkış koduyla başarısız olmasından (`EngineError.failed`) KASTEN AYRI bir tür:
/// çağıran "motor hata verdi" ile "süreç hiç bitmedi, biz kestik" durumunu
/// `catch let e as ProcessTimeoutError` / `catch is ProcessTimeoutError` ile ayırt edebilir.
/// `PDFOperation.swift`'teki `OperationError`'a yeni bir vaka olarak EKLENMEDİ çünkü bu dosyanın
/// sahiplik sınırı dışında — ayrı bir hata türü olarak burada tanımlanması hiçbir çağıranın
/// değişmesini gerektirmiyor (var olan `catch`'ler zaten türe göre ayırt etmiyorsa etkilenmez).
public struct ProcessTimeoutError: Error, LocalizedError, Equatable, Sendable {
  public let seconds: TimeInterval
  public init(seconds: TimeInterval) { self.seconds = seconds }
  public var errorDescription: String? {
    "Process timed out after \(Int(seconds)) seconds and was terminated"
  }
}

enum ProcessRunner {
  /// Varsayılan üst sınır. Gerekçe (2026-09-29 ölçümü): paketteki motorlarla ölçülen en yavaş
  /// GERÇEK koşu, 376 sayfalık bir dosyada Ghostscript ile 28,74 sn — 300 sn bunun ~10 katı,
  /// meşru hiçbir işi kesmez. Sınırsız bırakmak (`timeout: nil`) BUGÜNKÜ arızanın ta kendisi:
  /// bozuk/kötü niyetli bir PDF ya da disk G/Ç kilidi alt süreci sonsuza asabilir (ör.
  /// GHSA-fjh6-rrhv-4g63 — paketlenen pdfcpu'nun ≤v0.15.0 sürümünü etkileyen küçük girdiyle
  /// bellek tükenmesi danışmanlığı) ve zaman aşımı olmadan GUI/CLI de sonsuza kadar
  /// "çalışıyor" görünür kalır. Bu yüzden varsayılan makul bir tavan, sınırsız değil.
  static let defaultTimeout: TimeInterval = 300

  /// Alt süreci çalıştırır, stdout'u satır satır iletir, bitince sonucu döner.
  ///
  /// - Task iptal edilirse süreç `terminate()` ile sonlandırılır (davranış DEĞİŞMEDİ).
  /// - `timeout` dolarsa süreç önce `terminate()` (SIGTERM) ile, 2 sn içinde kendiliğinden
  ///   kapanmazsa `SIGKILL` ile sonlandırılır ve `ProcessTimeoutError` fırlatılır — zombi süreç
  ///   bırakılmaz. `timeout: nil` geçilirse sınırsız beklenir (bilinçli opt-out; varsayılan
  ///   parametre sayesinde mevcut çağıranların HİÇBİRİ değişmek zorunda değil).
  static func run(
    _ executable: URL,
    arguments: [String],
    timeout: TimeInterval? = defaultTimeout,
    onOutputLine: (@Sendable (String) -> Void)? = nil
  ) async throws -> ProcessResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let (termination, terminationContinuation) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { finished in
      terminationContinuation.yield(finished.terminationStatus)
      terminationContinuation.finish()
    }

    return try await withTaskCancellationHandler {
      try process.run()
      // Yarış: iptal, run()'dan önce geldiyse onCancel terminate'i atlamıştır.
      if Task.isCancelled { process.terminate() }

      let stderrTask = Task.detached(priority: .utility) {
        String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      }

      // Zaman aşımı, gerçek işle YARIŞAN ayrı bir Task olarak kurulur (withThrowingTaskGroup
      // yerine tek bir yardımcı Task + `defer`'la iptal — burada iki sonuç türünü birleştirmeye
      // gerek olmadığı için daha basit). İki uç durumda da sızıntı yok:
      //   · İş önce biterse: `defer` bu Task'ı `cancel()` eder, içindeki `Task.sleep`
      //     CancellationError ile ANINDA uyanır ve fonksiyon sessizce döner — ne bekleyen bir
      //     Task ne de dokunulmuş bir süreç kalır.
      //   · Zaman aşımı önce dolarsa: watchdog önce bayrağı işaretler, SONRA süreci sonlandırır
      //     (sıra önemli — aşağıdaki kontrol bayrağı okuduğunda kesin doğru olsun diye); süreç
      //     ölünce pipe EOF verir, ana akıştaki `for try await` döngüsü + terminationHandler
      //     kendiliğinden çözülür, fonksiyon normal akışta devam eder.
      let watchdog = timeout.map { TimeoutWatchdog(limit: $0, process: process) }
      let timeoutTask = watchdog.map { watchdog in Task.detached { await watchdog.wait() } }
      defer { timeoutTask?.cancel() }

      var stdout = ""
      for try await line in outPipe.fileHandleForReading.bytes.lines {
        stdout += line + "\n"
        onOutputLine?(line)
      }
      var status: Int32 = -1
      for await value in termination { status = value }
      // terminate() sonrası pipe normal EOF verir; gerçek iptali durum kodundan ayır.
      try Task.checkCancellation()
      if let watchdog, await watchdog.fired {
        throw ProcessTimeoutError(seconds: watchdog.limit)
      }
      return ProcessResult(status: status, stdout: stdout, stderr: await stderrTask.value)
    } onCancel: {
      if process.isRunning { process.terminate() }
    }
  }
}

/// Zaman aşımı bayrağını ve sonlandırma adımlarını tutan yardımcı. `actor` seçildi çünkü `fired`
/// bayrağına hem watchdog Task'ından (yazan) hem de ana akıştan (okuyan) veri yarışı olmadan
/// erişilmesi gerekiyor; `DispatchQueue` ile yarı-senkron bir çözüm KASTEN kullanılmadı (ana
/// actor'ü bloklamadan, salt `async`/`await` ile kooperatif bekleme).
private actor TimeoutWatchdog {
  let limit: TimeInterval
  private let process: Process
  private(set) var fired = false

  init(limit: TimeInterval, process: Process) {
    self.limit = limit
    self.process = process
  }

  func wait() async {
    try? await Task.sleep(nanoseconds: UInt64((limit * 1_000_000_000).rounded()))
    guard !Task.isCancelled else { return }
    fired = true
    await terminateForcibly()
  }

  /// Önce SIGTERM (`terminate()`), süreç 2 sn içinde kendiliğinden kapanmazsa SIGKILL.
  /// Bekleme `Task.sleep` ile kooperatif yapılır (busy-wait/`usleep` YOK) — thread havuzunu asmaz.
  private func terminateForcibly() async {
    guard process.isRunning else { return }
    process.terminate()
    let step: UInt64 = 50_000_000  // 50 ms
    let grace: UInt64 = 2_000_000_000  // 2 sn
    var waited: UInt64 = 0
    while process.isRunning && waited < grace {
      try? await Task.sleep(nanoseconds: step)
      waited += step
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
  }
}
