import CoreGraphics
import Foundation

/// "Şifrele" çıktısının GERÇEKTEN şifrelendiğini doğrular — qpdf'in çıkış kodu 0 döndürmesi tek
/// başına kanıt DEĞİL (bkz. `TrimVerification`/`MergeVerification`'daki aynı gerekçe: motora değil,
/// çıktının kendisine bak). Kanıt zinciri: `CGPDFDocument.isEncrypted == true`, DOĞRU kullanıcı
/// parolasıyla açılabiliyor, YANLIŞ parolayla açılamıyor — son ikisi asıl kanıt, "şifreleme fiilen
/// uygulandı"nı gösterir (bkz. `Tur4Tests` mutasyon testi: bu fonksiyon kasten "hep true dön" diye
/// bozulup kırmızı aldığı doğrulanır).
public enum EncryptVerification {
  /// `userPassword` boşsa (yalnız sahip/owner parolası verilmiş dosya — `EncryptOperation`'da
  /// izin verilen bir durum) dosya zaten şifresiz açılır; `CGPDFDocument` `unlockWithPassword`
  /// ÇAĞRILMADAN `isUnlocked == true` döner (bu makinede ölçüldü, 2026-09-08). Bu durumda
  /// karşılaştırılacak bir kullanıcı parolası yok — yalnızca `isEncrypted` + okunabilirlik
  /// kontrol edilir.
  public static func verify(_ url: URL, userPassword: String) -> Bool {
    guard let probe = CGPDFDocument(url as CFURL), probe.isEncrypted else { return false }

    guard !userPassword.isEmpty else {
      return probe.isUnlocked && probe.numberOfPages > 0
    }

    // Her deneme TAZE bir CGPDFDocument örneğiyle: unlockWithPassword bir örneğin durumunu
    // kalıcı olarak değiştirir, aynı örnek üzerinde iki farklı parola denenemez.
    guard let correctAttempt = CGPDFDocument(url as CFURL) else { return false }
    guard correctAttempt.unlockWithPassword(userPassword), correctAttempt.numberOfPages > 0 else {
      return false
    }

    guard let wrongAttempt = CGPDFDocument(url as CFURL) else { return false }
    let wrongUnlocked = wrongAttempt.unlockWithPassword(userPassword + "-yanlis-deneme")
    guard !wrongUnlocked else { return false }

    return true
  }
}
