import Foundation

public enum OutputNaming {
  /// Tur 10'da sabitlenen çıktı eki sözlüğü. Zincirleme işlemlerde (sıkıştır → filigran →
  /// sayfa numarası) adın `kitap_compressed_watermarked_numbered.pdf` diye büyümesini önlemek
  /// için kullanılır: yeni ek eklenmeden ÖNCE addaki bilinen ekler soyulur, böylece kullanıcı
  /// elinde her zaman son işlemi anlatan tek bir okunur ad bulur (Nadir, 2026-09-09).
  ///
  /// Bilinçli taviz: ad yalnız SON işlemi anlatır, tüm geçmişi değil. Dosya içeriği elbette
  /// tüm işlemleri taşır; ad kısa ve okunur olsun diye geçmiş adda tutulmuyor.
  public static let knownSuffixes: [String] = [
    "_unlocked", "_trimmed", "_merged", "_parts", "_images", "_pages", "_compressed",
    "_encrypted", "_qr", "_web", "_repaired", "_embedded", "_ocr", "_searchable",
    "_watermarked", "_clean", "_numbered", "_bookmarks", "_bookmarked",
  ]

  /// Addaki bilinen çıktı eklerini sondan başlayarak soyar. Ad tamamen eriyecekse soymaz —
  /// "_ocr.pdf" gibi bir dosya adsız kalmamalı.
  public static func strippingKnownSuffixes(_ stem: String) -> String {
    var result = stem
    var changed = true
    while changed {
      changed = false
      for suffix in knownSuffixes where result.hasSuffix(suffix) {
        let trimmed = String(result.dropLast(suffix.count))
        guard !trimmed.isEmpty else { continue }
        result = trimmed
        changed = true
        break
      }
    }
    return result
  }

  /// `kitap.pdf` → `kitap_unlocked.pdf`; çakışırsa `kitap_unlocked 2.pdf`, `... 3.pdf`.
  /// `kitap_compressed.pdf` + `_numbered` → `kitap_numbered.pdf` (bkz. `knownSuffixes`).
  public static func uniqueURL(for input: URL, suffix: String, in directory: URL? = nil) -> URL {
    let dir = directory ?? input.deletingLastPathComponent()
    let base = strippingKnownSuffixes(input.deletingPathExtension().lastPathComponent)
    let stem = base + suffix
    let ext = input.pathExtension.isEmpty ? "pdf" : input.pathExtension
    var candidate = dir.appendingPathComponent(stem).appendingPathExtension(ext)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent("\(stem) \(counter)").appendingPathExtension(ext)
      counter += 1
    }
    return candidate
  }

  /// `kitap.pdf` + `_parts` → `kitap_parts/`; çakışırsa `kitap_parts 2/`, `... 3/` (dosyalarla
  /// aynı mantık, uzantı yok — çoklu çıktı üreten işlemler bir klasöre yazar).
  public static func uniqueDirectory(for input: URL, suffix: String, in directory: URL? = nil) -> URL {
    let dir = directory ?? input.deletingLastPathComponent()
    let base = strippingKnownSuffixes(input.deletingPathExtension().lastPathComponent)
    let stem = base + suffix
    var candidate = dir.appendingPathComponent(stem, isDirectory: true)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent("\(stem) \(counter)", isDirectory: true)
      counter += 1
    }
    return candidate
  }
}
