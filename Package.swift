// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "PDFTools",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  dependencies: [
    // Yalnız PDFToolsApp bu bağımlılığı kullanır — çekirdek (PDFToolsCore) ve CLI
    // (pdftools) ağ/GUI güncelleme kütüphanesi taşımaz.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
  ],
  targets: [
    .target(
      name: "PDFToolsCore",
      path: "Sources/PDFToolsCore",
      // tr.lproj/Localizable.strings — çeviri tablosu (bkz. Localization.swift).
      resources: [.process("Resources")]
    ),
    .executableTarget(
      name: "PDFToolsApp",
      dependencies: [
        "PDFToolsCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources/PDFToolsApp",
      // tr.lproj/Localizable.strings — arayüz metinlerinin çevirisi.
      resources: [.process("Resources")],
      // SwiftPM, Xcode'un aksine yürütülebilire otomatik @executable_path/../Frameworks
      // rpath'i eklemiyor. Sparkle.framework paket içinde Contents/Frameworks altına
      // kopyalanıyor (packaging/build.sh); bu rpath olmadan dyld açılışta çöküyor.
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]
    ),
    .executableTarget(
      name: "pdftools",
      dependencies: ["PDFToolsCore"],
      path: "Sources/pdftools"
    ),
    .testTarget(
      name: "PDFToolsCoreTests",
      dependencies: ["PDFToolsCore"],
      path: "Tests/PDFToolsCoreTests",
      resources: [.copy("Fixtures")]
    ),
  ]
)
