import Foundation

/// İngilizce sayı + ad birleşimi: 1 için tekil, diğerlerinde çoğul.
///
/// Türkçede sayıdan sonra ad çoğullanmaz ("3 dosya"), bu yüzden arayüz Türkçeden
/// İngilizceye çevrilirken "1 files" gibi ifadeler kaldı (ölçüldü 2026-09-09).
/// Düzensiz çoğullar için `plural` parametresi verilir.
func counted(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
  "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
}
