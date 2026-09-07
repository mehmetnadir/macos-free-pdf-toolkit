import Foundation
import PDFKit

/// `PageNumberOperation`'ın "hangi sayfada hangi metin (ya da HİÇ metin) olmalı" kuralını TEK
/// yerden hesaplar (`expectedNumber`/`expectedText`) — çizim VE üretim-içi doğrulama bu kuralı
/// AYRI AYRI hesaplayıp anlaşmazlığa düşmesin diye. `pageMatchesExpectation` PDFKit ile metni
/// GERİ OKUYUP üretim koduna güvenmeden gerçek çıktıyı denetler (bkz. `ExtractTextOperation`'ın
/// `PDFPage.string` kullanımıyla aynı çerçeve API'si).
///
/// NOT (kapsam sınırı): `expectedNumber`/`expectedText`, `PageNumberOperation.run()` İÇİNDE bir
/// doğrulama ADIMI olarak kullanılır — bu, çizim koduyla AYNI formülü paylaştığından "startAt/
/// format yorumu YANLIŞ ama ikisi de aynı yanlışta hemfikir" sınıfı bir hatayı YAKALAYAMAZ;
/// yalnızca render hattının (sayfa kopyalama/CTLineDraw/konum) GERÇEKTEN okunabilir metin
/// ürettiğini doğrular. Görev tanımının istediği BAĞIMSIZ kanıt bu yüzden `Tur7Tests`'te KENDİ
/// literal beklenen dizesini (`"3"`/`"3 / 6"`) doğrudan yazarak sağlanır — bu dosyadaki
/// fonksiyonlar ORADA çağrılmaz.
public enum PageNumberVerification {
  /// `pageIndex` (1-tabanlı) sayfada GÖSTERİLMESİ gereken sayı. `startAt == "0"` (kapak
  /// sayılmaz) VE `pageIndex == 1` ise `nil` (numara YOK) — aksi halde fiziksel sayfa
  /// numarasından kapak farkı (1) düşülür, böylece fiziksel 2. sayfa mantıksal "1" olur.
  public static func expectedNumber(forPage pageIndex: Int, startAt: String) -> Int? {
    if startAt == "0" {
      guard pageIndex > 1 else { return nil }
      return pageIndex - 1
    }
    return pageIndex
  }

  /// Sayfada çizilmesi/aranması gereken TAM metin (`format` "plain" → "5", "ofN" → "5 / 120").
  /// `nil` dönerse o sayfada HİÇ numara olmamalı.
  public static func expectedText(
    forPage pageIndex: Int, total: Int, startAt: String, format: String
  ) -> String? {
    guard let number = expectedNumber(forPage: pageIndex, startAt: startAt) else { return nil }
    return format == "ofN" ? "\(number) / \(total)" : "\(number)"
  }

  /// `url`'deki PDF'in `pageIndex` (1-tabanlı) sayfasını PDFKit ile açıp beklenen metnin (ya da
  /// numarasızlığın) GERÇEKTEN geçerli olduğunu doğrular. Sayfa/döküman açılamazsa `nil`
  /// (belirsiz — çağıran bunu "sayfa okunamadı" olarak ayrı ele alır, sessizce `false`'a düşmez).
  public static func pageMatchesExpectation(
    pdfAt url: URL, pageIndex: Int, total: Int, startAt: String, format: String
  ) -> Bool? {
    guard let document = PDFDocument(url: url), let page = document.page(at: pageIndex - 1) else {
      return nil
    }
    let text = page.string ?? ""
    guard
      let expected = expectedText(
        forPage: pageIndex, total: total, startAt: startAt, format: format)
    else {
      // Numarasız olması bekleniyor: sayfada HİÇBİR rakam olmamalı. Basit "rakam yok" kontrolü bu
      // proje için yeterli — `Tur7Tests` fixture'ları düz renkli dikdörtgen çizer, metin İÇERMEZ.
      return !text.contains(where: \.isNumber)
    }
    return text.contains(expected)
  }
}
