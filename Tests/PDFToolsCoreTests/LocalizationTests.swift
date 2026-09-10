import XCTest

@testable import PDFToolsCore

/// Çeviri sözleşmesi. Bu testin varlık sebebi: eksik çeviri SESSİZ bir arızadır — arayüz
/// çalışır, kullanıcı Türkçe seçer, bazı kartlar İngilizce kalır ve kimse fark etmez.
/// Burada her işlemin kullanıcıya görünen metinleri sayılıp Türkçe tabloda karşılığı ARANIR.
final class LocalizationTests: XCTestCase {
  private let turkish = Locale(identifier: "tr_TR")
  private let english = Locale(identifier: "en_US")

  /// Kayıttaki TÜM işlemlerin kullanıcıya görünen düz metinleri (içine değer gömülü olanlar
  /// hariç — onlar biçim anahtarlarıyla ayrıca ele alınır).
  private func userFacingStrings() -> [(text: String, source: String)] {
    var result: [(String, String)] = []
    for operation in OperationRegistry.all {
      result.append((operation.title, "\(operation.id).title"))
      result.append((operation.subtitle, "\(operation.id).subtitle"))
      result.append((operation.actionTitle, "\(operation.id).actionTitle"))
      for option in operation.options {
        result.append((option.label, "\(operation.id).\(option.id).label"))
        for choice in option.choices {
          result.append((choice.label, "\(operation.id).\(option.id).\(choice.value)"))
        }
      }
    }
    return result.filter { !$0.0.contains("\\(") }
  }

  func testEveryOperationStringHasATurkishTranslation() {
    let table = L10n.keys(for: .turkish)
    var missing: [String] = []
    for entry in userFacingStrings() where !table.contains(entry.text) {
      missing.append("\(entry.source): \"\(entry.text)\"")
    }
    XCTAssertTrue(
      missing.isEmpty,
      "Türkçe karşılığı olmayan \(missing.count) metin var — Türkçe seçen kullanıcı bunları "
        + "İngilizce görür:\n" + missing.sorted().joined(separator: "\n"))
  }

  func testTranslationActuallyChangesTheText() {
    // En az bir işlem başlığının Türkçesi İngilizcesinden FARKLI olmalı; tablo yüklenmemişse
    // (kaynak paketlenmemiş, .lproj yolu yanlış) her şey İngilizce döner ve bu test yakalar.
    let translated = OperationRegistry.all.filter {
      L10n.tr($0.title, locale: turkish) != $0.title
    }
    XCTAssertGreaterThan(
      translated.count, 0,
      "Hiçbir başlık çevrilmedi — Bundle.module içinde tr.lproj/Localizable.strings okunamıyor olabilir")
  }

  func testEnglishLocaleReturnsTheSourceTextUnchanged() {
    for entry in userFacingStrings().prefix(20) {
      XCTAssertEqual(L10n.tr(entry.text, locale: english), entry.text)
    }
  }

  /// Anahtar sızması: çevirisi olmayan metin AYNEN dönmeli. Soyut anahtar kullanan sistemlerin
  /// klasik arızası olan `op.trim.title` gibi çıplak anahtarın ekrana düşmesi bu tasarımda
  /// imkânsız — bunu ölçüyoruz.
  func testUnknownTextFallsBackToItselfAndNeverLeaksAKey() {
    let unknown = "This sentence is deliberately absent from every translation table"
    XCTAssertEqual(L10n.tr(unknown, locale: turkish), unknown)
    XCTAssertEqual(L10n.tr("", locale: turkish), "")
  }

  func testFormattedTextAppliesArgumentsInBothLocales() {
    XCTAssertEqual(L10n.text("%d of %d", locale: english, 3, 20), "3 of 20")
    // Türkçe biçim dizgesi tabloda olmasa bile argümanlar uygulanmalı (İngilizce biçimle).
    let turkishResult = L10n.text("%d of %d", locale: turkish, 3, 20)
    XCTAssertTrue(turkishResult.contains("3"), turkishResult)
    XCTAssertTrue(turkishResult.contains("20"), turkishResult)
  }

  /// Türkçe metinlerde ASCII bozulması olmamalı: "için" → "icin" gibi bir düşüş, dosyanın
  /// yanlış kodlamayla yazıldığının işareti. Ayrıca U+FFFD (replacement char) hiç olmamalı.
  func testTurkishTableKeepsTurkishCharacters() {
    let table = L10n.keys(for: .turkish)
    guard !table.isEmpty else { return XCTFail("Türkçe tablo boş") }
    let values = table.compactMap { L10n.tr($0, locale: turkish) }
    let joined = values.joined()
    XCTAssertFalse(joined.contains("\u{FFFD}"), "çeviri tablosunda bozuk karakter var")
    let turkishSpecific = CharacterSet(charactersIn: "çöüğışÇÖÜĞİŞ")
    XCTAssertTrue(
      joined.rangeOfCharacter(from: turkishSpecific) != nil,
      "Türkçe tabloda hiç Türkçe karakter yok — ASCII'ye düşürülmüş olabilir")
  }
}
