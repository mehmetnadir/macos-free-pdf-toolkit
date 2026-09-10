cask "pdf-tools" do
  version "0.1.0"
  # NOT: henüz yayın yapılmadı — bu placeholder'ı gerçek sha256 ile değiştir.
  # Doldurma yöntemleri:
  #   1) Otomatik: packaging/release.sh RELEASE_CONFIRM=1 ile koşulduğunda bu alanı
  #      kendisi günceller (DMG'nin sha256'sını hesaplayıp dosyayı düzenler).
  #   2) Elle: `shasum -a 256 build/PDF-Tools-#{version}.dmg` çıktısını buraya yapıştır.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/mehmetnadir/macos-free-pdf-toolkit/releases/download/v#{version}/PDF-Tools-#{version}.dmg"
  name "PDF Tools"
  desc "Local PDF toolkit that verifies its own output"
  homepage "https://github.com/mehmetnadir/macos-free-pdf-toolkit"

  # Uygulama Sparkle 2.9.6 ile kendi kendini günceller — brew'in kendi güncelleme
  # denemesiyle ÇAKIŞMAMASI için bu satır zorunlu (brew upgrade artık bu cask'i
  # "otomatik güncellenir" sayıp atlar).
  auto_updates true
  # LSMinimumSystemVersion (packaging/Info.plist) 14.0 — Sonoma altı desteklenmiyor.
  depends_on macos: :sonoma

  app "PDF Tools.app"

  # Yalnız `brew uninstall --zap` ile koşar — kullanıcının PDF'lerine DOKUNMAZ,
  # sadece uygulamanın kendi tercih/önbellek yolları (Sparkle önbelleği dahil).
  zap trash: [
    "~/Library/Caches/com.ydspublishing.pdftools",
    "~/Library/Preferences/com.ydspublishing.pdftools.plist",
  ]
end
