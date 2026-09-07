import Foundation

public enum OutputNaming {
  /// `kitap.pdf` → `kitap_unlocked.pdf`; çakışırsa `kitap_unlocked 2.pdf`, `... 3.pdf`.
  public static func uniqueURL(for input: URL, suffix: String, in directory: URL? = nil) -> URL {
    let dir = directory ?? input.deletingLastPathComponent()
    let stem = input.deletingPathExtension().lastPathComponent + suffix
    let ext = input.pathExtension.isEmpty ? "pdf" : input.pathExtension
    var candidate = dir.appendingPathComponent(stem).appendingPathExtension(ext)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent("\(stem) \(counter)").appendingPathExtension(ext)
      counter += 1
    }
    return candidate
  }
}
