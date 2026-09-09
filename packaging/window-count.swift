// Verilen PID'e ait GÖRÜNÜR içerik penceresi sayısını basar.
// packaging/build.sh içindeki açılış duman testi kullanır: "süreç ayakta ama 0 pencere"
// arızası sessizdir (çökme yok, log yok) ve yalnız böyle sayarak yakalanır.
// Menü çubuğu şeritleri 30 pikselden alçaktır, içerik penceresi sayılmaz.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
  FileHandle.standardError.write(Data("kullanım: window-count.swift <pid>\n".utf8))
  exit(2)
}
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
let count = (info ?? []).filter { window in
  guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == pid,
    let bounds = window[kCGWindowBounds as String] as? [String: Any],
    let height = bounds["Height"] as? Double
  else { return false }
  return height > 30
}.count
print(count)
