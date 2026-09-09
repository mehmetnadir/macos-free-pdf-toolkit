import Foundation

/// Kullanıcının KENDİ makinesine kurması gereken bir dış araç.
///
/// Neden var: Ghostscript AGPL-3.0. Pakete gömersek tüm dağıtım AGPL olur; bu yüzden
/// gömmüyoruz (bkz. THIRD_PARTY.md). Ama "gs kurulu değil" deyip kullanıcıyı orada bırakmak
/// da çözüm değil — Nadir'in tarifi: "kurulu değil, kurun, şöyle kurun, dönün" (2026-09-09).
/// Kullanıcı aracı kendi kurar, biz AGPL kod dağıtmayız, iş de görülür.
///
/// Metinler burada, arayüzde değil: aynı bilgi hem kurulum sayfasında hem hata mesajında
/// geçiyor, iki yere yazılırsa biri güncellenmeden kalır.
public struct ToolRequirement: Sendable, Equatable, Identifiable {
  public var id: String { name }
  /// Kullanıcının göreceği araç adı.
  public let name: String
  /// Bu araç NE İÇİN gerekiyor — kullanıcının diliyle, işlev adıyla.
  public let purpose: String
  /// Neden uygulamayla birlikte gelmediği. Kullanıcı "niye ben kuruyorum" diye sorar.
  public let whyNotBundled: String
  /// Kopyalanıp yapıştırılacak kurulum komutu.
  public let installCommand: String
  /// Resmi kurulum sayfası (Homebrew yoksa oradan indirir).
  public let homepage: URL

  public init(
    name: String, purpose: String, whyNotBundled: String, installCommand: String, homepage: URL
  ) {
    self.name = name
    self.purpose = purpose
    self.whyNotBundled = whyNotBundled
    self.installCommand = installCommand
    self.homepage = homepage
  }

  public static let ghostscript = ToolRequirement(
    name: "Ghostscript",
    purpose: "the Strong compression level, which also shrinks the images inside the PDF",
    whyNotBundled:
      "Ghostscript is licensed under the AGPL, which would apply to this app as a whole if it "
      + "shipped inside it. Installing it yourself keeps both licences clean — and it stays on "
      + "your Mac for other apps too.",
    installCommand: "brew install ghostscript",
    homepage: URL(string: "https://ghostscript.com/releases/gsdnld.html")!)
}
