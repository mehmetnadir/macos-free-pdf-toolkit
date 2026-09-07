// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "PDFTools",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "PDFToolsCore",
      path: "Sources/PDFToolsCore"
    ),
    .executableTarget(
      name: "PDFToolsApp",
      dependencies: ["PDFToolsCore"],
      path: "Sources/PDFToolsApp"
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
