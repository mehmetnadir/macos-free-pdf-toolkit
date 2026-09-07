import CoreGraphics
import Foundation

/// "Sayfa Düzenle" çıktısının doğruluğunu ölçer. Motora GÜVENMEZ — qpdf'in çıkış kodu 0/3 olması
/// yalnızca "hata vermeden bitti" demektir, "plan doğru uygulandı" demek değildir. İki BAĞIMSIZ
/// sinyal ölçülür:
///
/// 1. **Sıra/silme doğruluğu**: çıktı sayfasının HAM pikseli, plandaki kaynak sayfanın ham
///    pikseliyle eşleşiyor mu (`MergeVerification.pagesMatch` yeniden kullanılır). Bu kontrol
///    döndürmeden BAĞIMSIZ hep geçerlidir çünkü qpdf'in `--rotate`'i içerik akışını değiştirmez
///    (aşağıya bkz.) — yanlış sayfanın yanlış konuma taşınmasını yakalar.
/// 2. **Döndürme doğruluğu**: çıktı sayfasının `/Rotate` değeri (`CGPDFPage.rotationAngle` ile
///    BAĞIMSIZCA yeniden okunur — qpdf'in kendi raporuna değil, CoreGraphics'in PDF'i nasıl
///    yorumladığına bakılır) plandaki hedef dereceyle eşleşiyor mu.
///
/// ÖLÇÜLDÜ (2026-09-07, scratchpad): qpdf'in `--rotate`'i yalnızca sayfa sözlüğündeki `/Rotate`
/// bayrağını yazar; ne içerik akışını (glif/çizim koordinatları) ne de `MediaBox`'ı FİZİKSEL olarak
/// döndürür/takas eder — bu tam olarak PDF spesifikasyonunun `/Rotate` semantiğidir (görüntüleyici
/// GÖSTERİRKEN döndürür). `CGContext.drawPDFPage` da bu bayrağı OTOMATİK uygulamaz (TrimVerification
/// yorumundaki "drawPDFPage kutuya göre kırpmaz" ile aynı ailede bir Quartz davranışı) — yani ham
/// piksel karşılaştırması rotasyondan etkilenmez, dolayısıyla (1) ve (2) birbirinden BAĞIMSIZ iki
/// gerçek sinyaldir; biri diğerini örtmez. `effectiveSize(of:)`, 90/270'te GÖRÜNTÜLENEN (viewer'ın
/// göstereceği) genişlik/yüksekliğin takas edildiğini bu bayraktan türetip raporlamak/test etmek
/// için ayrı bir yardımcıdır — `MediaBox`'ın kendisi hiç fiziksel takas OLMADIĞI için bunu doğrudan
/// bir "eşitlik" gate'i olarak kullanmak (2)'nin tekrarından öteye geçmez; bu yüzden gate'e değil,
/// yalnızca kutunun KORUNDUĞUNU (bozulmadığını) doğrulayan ayrı bir sağlamlık kontrolüne dahil edilir.
public enum PageEditVerification {
  public enum Verdict: Sendable, Equatable {
    case clean
    case failed
  }

  public struct Result: Sendable, Equatable {
    public let verdict: Verdict
    public let message: String
  }

  /// `input`'un `plan.order`'a göre yeniden sıralanıp/silinip/döndürülmüş hâlinin `output`'a doğru
  /// yazıldığını doğrular. Sayfa açılamıyorsa ya da herhangi bir kontrol tutmuyorsa `.failed` döner.
  public static func verify(input: URL, plan: PageEditPlan, output: URL) -> Result {
    guard let outDoc = CGPDFDocument(output as CFURL) else {
      return Result(verdict: .failed, message: "çıktı açılamadı")
    }
    guard outDoc.numberOfPages == plan.order.count else {
      return Result(
        verdict: .failed,
        message: "çıktı \(outDoc.numberOfPages) sayfa, plan \(plan.order.count) sayfa bekliyordu")
    }
    guard let inDoc = CGPDFDocument(input as CFURL) else {
      return Result(verdict: .failed, message: "kaynak açılamadı")
    }

    for (index, sourcePage) in plan.order.enumerated() {
      let outputPage = index + 1
      guard let srcPage = inDoc.page(at: sourcePage), let outPage = outDoc.page(at: outputPage)
      else {
        return Result(verdict: .failed, message: "sayfa \(outputPage) açılamadı")
      }

      // 1) İçerik/konum: kaynağın plandaki sayfası ham pikselde çıktının bu konumuna taşınmış mı.
      guard
        MergeVerification.pagesMatch(
          input: input, inputPage: sourcePage, output: output, outputPage: outputPage)
      else {
        return Result(
          verdict: .failed,
          message:
            "çıktı sayfa \(outputPage), kaynağın \(sourcePage). sayfasıyla piksel düzeyinde eşleşmiyor"
        )
      }

      // 2) Döndürme: hedef derece, ÇIKTIDAN bağımsızca yeniden okunan `/Rotate` ile eşleşiyor mu.
      let expectedDegree = plan.rotations[sourcePage] ?? 0
      let actualDegree = normalizedDegree(outPage.rotationAngle)
      guard actualDegree == expectedDegree else {
        return Result(
          verdict: .failed,
          message:
            "çıktı sayfa \(outputPage) döndürme derecesi \(actualDegree), beklenen \(expectedDegree)"
        )
      }

      // 3) Sağlamlık: kutu bozulmamış (qpdf `/Rotate` yazarken MediaBox'ı fiziksel DEĞİŞTİRMEZ —
      // bu yüzden ham kutu her zaman kaynakla eşit kalmalı; farklıysa başka bir bozulma var demektir).
      let sourceBox = srcPage.getBoxRect(.mediaBox)
      let outputBox = outPage.getBoxRect(.mediaBox)
      guard abs(outputBox.width - sourceBox.width) < 0.5,
        abs(outputBox.height - sourceBox.height) < 0.5
      else {
        return Result(
          verdict: .failed,
          message:
            "çıktı sayfa \(outputPage) kutusu (\(outputBox.width)×\(outputBox.height)) "
            + "kaynağınkiyle (\(sourceBox.width)×\(sourceBox.height)) uyuşmuyor")
      }
    }

    return Result(verdict: .clean, message: "\(plan.order.count) sayfa doğrulandı")
  }

  /// Bir sayfanın GÖRÜNTÜLENEN (rotasyon uygulanmış) boyutu. `/Rotate` 90 ya da 270 ise ham
  /// `MediaBox`'ın genişlik/yüksekliği TAKAS edilir — qpdf (ve PDF spesifikasyonu) kutuyu fiziksel
  /// değiştirmez, yalnızca görüntüleyicinin bu bayrağa göre takas etmesi BEKLENİR. Raporlama ve
  /// testler için (bkz. tip yorumu — `verify()` içindeki gate'e dahil edilmez, orada zaten doğrudan
  /// `rotationAngle` karşılaştırılıyor).
  public static func effectiveSize(of page: CGPDFPage) -> CGSize {
    let box = page.getBoxRect(.mediaBox)
    let degree = normalizedDegree(page.rotationAngle)
    return degree == 90 || degree == 270 ? CGSize(width: box.height, height: box.width) : box.size
  }

  private static func normalizedDegree(_ raw: Int32) -> Int {
    ((Int(raw) % 360) + 360) % 360
  }
}
