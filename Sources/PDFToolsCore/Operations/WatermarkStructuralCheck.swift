import Foundation

/// `WatermarkVerification`'ın piksel-eşik yöntemi (mürekkep oranı) YOĞUN/renkli sayfalarda
/// SATÜRE oluyor — ölçüldü (2026-09-29, gerçek dosyalarla): 9 sayfalık renkli bir çalışma
/// kitabında kaynak bölge zaten %92,79 mürekkep, filigran çizildikten SONRA %92,91 (fark
/// %0,12); 376 sayfalık bir soru bankasında %88,59 → %88,62 (fark %0,03). İkisinde de filigran
/// GERÇEKTEN çizildi (aşağıdaki gibi doğrulandı) ama piksel farkı eski eşiğin (%0,3) fersah
/// fersah altında kaldı — çünkü ölçüm ikili bir "mürekkep var/yok" eşiğine (luma<250)
/// dayanıyor ve bölge zaten neredeyse tamamen "mürekkepli" sayılan piksellerle doluyken, üstüne
/// %15 opaklıkla gri bir metin eklemek eşiği zaten aşmış pikselleri tekrar "mürekkepli"
/// saydırmıyor — sinyal SIFIRA yakın kalıyor.
///
/// Bu dosya motora (kendi çizim kodumuza) güvenmeden BAĞIMSIZ bir YAPISAL kanıt üretir:
/// çıktının içerik akışında GERÇEKTEN bir metin gösterme operatörü (`Tj`/`TJ`, boş olmayan) var
/// mı, beklenen konumda (merkezde 45° döndürülmüş `cm`, üst/altta sayfanın doğru yarısında
/// `Tm`). `WatermarkAddOperation` artık İKİ eksenden kanıt istiyor: YAPISAL (birincil, bu
/// dosya) + PİKSEL (ikincil/doğrulayıcı, sıfır olmadığını doğrular) — bkz. dosya üstü yorumu.
///
/// NEDEN q/Q DERİNLİĞİ İZLENMİYOR (ölçüldü, gerçek çıktılarla): CoreGraphics'in PDF yazıcısı
/// `ctx.saveGState()`/`ctx.restoreGState()` çağrılarımızı literal `q`/`Q` ile BİREBİR
/// eşlemiyor — sayfa başında marked-content için açtığı bir `q` sayfa SONUNA kadar kapanmadan
/// kalabiliyor, renk/alfa durumu ayrı bir `q` olmadan doğrudan yazılabiliyor, döndürme için ayrı
/// bir iç içe `q`/`Q` çıkabiliyor. Derinlik takibiyle "bizim bloğumuz"nu ayırmak Apple'ın iç
/// uygulama detayına bağımlı olur ve gelecekte sessizce kırılabilir. Bunun yerine PDF'in KENDİ
/// kuralına dayanılıyor: metin nesneleri (`BT...ET`) iç içe OLAMAZ ve biz kendi metnimizi HER
/// ZAMAN kaynak sayfa tamamen kopyalandıktan SONRA çiziyoruz (`WatermarkAddOperation
/// .writeOutput` çağrı sırası: önce `ctx.drawPDFPage(page)`, sonra filigran) — yani akıştaki EN
/// SON `BT...ET` bloğu, kaynağın içeriği ne kadar karmaşık olursa olsun (kendi metnini de
/// içerebilir), HER ZAMAN bizim filigranımızdır.
enum WatermarkStructuralCheck {
  /// İçerik akışının en son metin nesnesinden (`BT...ET`) ve ondan önceki en yakın `cm`'den
  /// çıkarılan kanıt.
  struct Evidence {
    /// Blokta bir yazı tipi seçme operatörü (`Tf`) var mı.
    let hasFont: Bool
    /// Blokta boş OLMAYAN bir dizgeyle bir metin gösterme operatörü (`Tj`/`TJ`) var mı.
    let hasNonEmptyShow: Bool
    /// `BT`'den ÖNCEKİ en son `cm`'in (a, b, c, d) bileşenleri — varsa.
    let rotation: (a: Double, b: Double, c: Double, d: Double)?
    /// Blok içindeki İLK `Tm`'in 6. operandı (ty) — varsa.
    let textMatrixTY: Double?

    /// Kanıt 2a — GERÇEKTEN bir şey çizilmiş mi (yazı tipi + boş olmayan gösterme).
    var textWasShown: Bool { hasFont && hasNonEmptyShow }
  }

  /// `content`'i tara, EN SON `BT...ET` bloğunu bul, onu ve ondan önceki en yakın `cm`'i
  /// analiz et. Hiç `BT` yoksa (filigran hiç çizilmemiş demektir) `nil` döner.
  static func analyze(_ content: [UInt8]) -> Evidence? {
    let tokens = tokenize(content)
    guard
      let btIndex = tokens.lastIndex(where: { $0.isOperator("BT") })
    else { return nil }
    guard
      let etIndex = tokens[(btIndex + 1)...].firstIndex(where: { $0.isOperator("ET") })
    else { return nil }

    let block = tokens[(btIndex + 1)..<etIndex]
    let hasFont = block.contains { $0.isOperator("Tf") }
    let hasShowOp = block.contains { $0.isOperator("Tj") || $0.isOperator("TJ") }
    let hasNonEmptyString = block.contains {
      if case .string(let length) = $0.kind { return length > 0 }
      return false
    }

    var textMatrixTY: Double?
    if let tmIndex = block.firstIndex(where: { $0.isOperator("Tm") }) {
      let operands = numbers(precedingTokenAt: tmIndex, in: tokens)
      textMatrixTY = operands.last
    }

    var rotation: (Double, Double, Double, Double)?
    if let cmIndex = tokens[..<btIndex].lastIndex(where: { $0.isOperator("cm") }) {
      let operands = numbers(precedingTokenAt: cmIndex, in: tokens)
      if operands.count >= 6 {
        let last6 = Array(operands.suffix(6))
        rotation = (last6[0], last6[1], last6[2], last6[3])
      }
    }

    return Evidence(
      hasFont: hasFont, hasNonEmptyShow: hasShowOp && hasNonEmptyString, rotation: rotation,
      textMatrixTY: textMatrixTY)
  }

  /// `WatermarkAddOperation`'ın "center" konumunda çizdiği 45°'lik döndürmeye (bkz.
  /// `ctx.rotate(by: .pi / 4)`) makul bir toleransla uyuyor mu.
  static func looksLikeDiagonalRotation(_ rotation: (a: Double, b: Double, c: Double, d: Double)?)
    -> Bool
  {
    guard let r = rotation else { return false }
    let expected = 0.7071068
    let tolerance = 0.08
    return abs(r.a - expected) < tolerance && abs(r.d - expected) < tolerance
      && abs(r.b - expected) < tolerance && abs(r.c + expected) < tolerance
  }

  // MARK: - Tokenizer

  enum TokenKind: Equatable {
    case op(String)
    case number(Double)
    case name(String)
    case string(length: Int)
    case arrayOpen, arrayClose, dictOpen, dictClose
  }

  struct Token: Equatable {
    let kind: TokenKind
    func isOperator(_ name: String) -> Bool {
      if case .op(let value) = kind { return value == name }
      return false
    }
  }

  /// `at`'teki operatörden HEMEN ÖNCE gelen ardışık sayı dizisini (orijinal sırayla) döner —
  /// `cm`/`Tm` gibi operatörlerin operandlarını toplamak için.
  private static func numbers(precedingTokenAt index: Int, in tokens: [Token]) -> [Double] {
    var values: [Double] = []
    var i = index - 1
    while i >= 0, case .number(let value) = tokens[i].kind {
      values.append(value)
      i -= 1
    }
    return values.reversed()
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
  }

  private static func isDelimiter(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
    default: return false
    }
  }

  /// PDF içerik akışı sözde-dilinin minimal bir tarayıcısı: dizgeleri (literal/hex), adları,
  /// sayıları ve çıplak operatör/anahtar sözcükleri ayırt eder; satır içi görüntüleri
  /// (`BI...ID...EI`) İÇİNDEKİ HAM İKİLİ VERİYİ atlar (aksi halde rastgele baytlar `q`/`Q`/`BT`
  /// gibi görünüp analizle bozabilirdi). Yalnız BU dosyanın ihtiyacı kadarını çözer — genel bir
  /// PDF ayrıştırıcısı DEĞİL.
  static func tokenize(_ bytes: [UInt8]) -> [Token] {
    var tokens: [Token] = []
    var i = 0
    let n = bytes.count
    while i < n {
      let b = bytes[i]
      if isWhitespace(b) {
        i += 1
        continue
      }
      if b == 0x25 {  // '%' — satır sonuna kadar yorum
        while i < n, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
        continue
      }
      if b == 0x28 {  // '(' literal dizge
        i += 1
        var depth = 1
        var length = 0
        while i < n, depth > 0 {
          let c = bytes[i]
          if c == 0x5C {  // '\' kaçış
            i += 1
            guard i < n else { break }
            let e = bytes[i]
            if e >= 0x30, e <= 0x37 {  // sekizlik kaçış, en fazla 3 hane
              var digits = 1
              i += 1
              while digits < 3, i < n, bytes[i] >= 0x30, bytes[i] <= 0x37 {
                i += 1
                digits += 1
              }
              length += 1
            } else if e == 0x0D || e == 0x0A {  // satır devamı — bayt KATKISI YOK
              i += 1
              if e == 0x0D, i < n, bytes[i] == 0x0A { i += 1 }
            } else {
              length += 1
              i += 1
            }
          } else if c == 0x28 {
            depth += 1
            length += 1
            i += 1
          } else if c == 0x29 {
            depth -= 1
            i += 1
            if depth > 0 { length += 1 }
          } else {
            length += 1
            i += 1
          }
        }
        tokens.append(Token(kind: .string(length: length)))
        continue
      }
      if b == 0x3C {  // '<'
        if i + 1 < n, bytes[i + 1] == 0x3C {
          tokens.append(Token(kind: .dictOpen))
          i += 2
          continue
        }
        i += 1
        var hexDigits = 0
        while i < n, bytes[i] != 0x3E {
          let c = bytes[i]
          let isHex =
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
          if isHex { hexDigits += 1 }
          i += 1
        }
        if i < n { i += 1 }  // '>' atla
        tokens.append(Token(kind: .string(length: (hexDigits + 1) / 2)))
        continue
      }
      if b == 0x3E {
        if i + 1 < n, bytes[i + 1] == 0x3E {
          tokens.append(Token(kind: .dictClose))
          i += 2
          continue
        }
        i += 1  // başıboş '>' — savunmacı atlama
        continue
      }
      if b == 0x5B {
        tokens.append(Token(kind: .arrayOpen))
        i += 1
        continue
      }
      if b == 0x5D {
        tokens.append(Token(kind: .arrayClose))
        i += 1
        continue
      }
      if b == 0x2F {  // '/' ad
        i += 1
        var chars: [UInt8] = []
        while i < n, !isWhitespace(bytes[i]), !isDelimiter(bytes[i]) {
          chars.append(bytes[i])
          i += 1
        }
        tokens.append(Token(kind: .name(String(decoding: chars, as: UTF8.self))))
        continue
      }
      if b == 0x7B || b == 0x7D {  // PostScript hesaplayıcı süslü parantezleri — yok say
        i += 1
        continue
      }
      // Sayı ya da çıplak operatör/anahtar sözcük.
      let isNumberStart = (b >= 0x30 && b <= 0x39) || b == 0x2B || b == 0x2D || b == 0x2E
      var chars: [UInt8] = []
      while i < n, !isWhitespace(bytes[i]), !isDelimiter(bytes[i]) {
        chars.append(bytes[i])
        i += 1
      }
      let word = String(decoding: chars, as: UTF8.self)
      if isNumberStart, let value = Double(word) {
        tokens.append(Token(kind: .number(value)))
      } else {
        tokens.append(Token(kind: .op(word)))
        if word == "ID" {
          // Satır içi görüntü: "ID"den sonra HAM İKİLİ VERİ gelir, normal belirteçleme
          // KURALLARINA uymaz — boşluk+"EI"+sınırlayıcı/boşluk/dosya-sonu bulunana kadar atla.
          i = skipInlineImageData(bytes, from: i)
        }
      }
    }
    return tokens
  }

  private static func skipInlineImageData(_ bytes: [UInt8], from start: Int) -> Int {
    var i = start
    let n = bytes.count
    if i < n, isWhitespace(bytes[i]) { i += 1 }  // "ID"den sonraki TEK ayırıcı boşluk
    var j = i
    while j + 1 < n {
      let precededByWhitespace = j == i || isWhitespace(bytes[j - 1])
      if precededByWhitespace, bytes[j] == 0x45, bytes[j + 1] == 0x49 {  // "EI"
        let followedByBoundary = (j + 2 >= n) || isWhitespace(bytes[j + 2])
        if followedByBoundary { return j + 2 }
      }
      j += 1
    }
    return n
  }
}
