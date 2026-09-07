import Foundation

struct ProcessResult: Sendable {
  let status: Int32
  let stdout: String
  let stderr: String
}

enum ProcessRunner {
  /// Alt süreci çalıştırır, stdout'u satır satır iletir, bitince sonucu döner.
  /// Task iptal edilirse süreç sonlandırılır.
  static func run(
    _ executable: URL,
    arguments: [String],
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
      var stdout = ""
      for try await line in outPipe.fileHandleForReading.bytes.lines {
        stdout += line + "\n"
        onOutputLine?(line)
      }
      var status: Int32 = -1
      for await value in termination { status = value }
      // terminate() sonrası pipe normal EOF verir; gerçek iptali durum kodundan ayır.
      try Task.checkCancellation()
      return ProcessResult(status: status, stdout: stdout, stderr: await stderrTask.value)
    } onCancel: {
      if process.isRunning { process.terminate() }
    }
  }
}
