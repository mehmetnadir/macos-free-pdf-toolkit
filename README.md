[Türkçe](README.tr.md)

# PDF Tools

[![CI](https://github.com/mehmetnadir/macos-free-pdf-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/mehmetnadir/macos-free-pdf-toolkit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

A free, local, native macOS PDF toolbox — no upload, no subscription.

![PDF Araçları](docs/screenshot.png)

## Features

- **Unlock** — remove owner/user passwords and restrictions from encrypted PDFs, entirely on-device.
- **Trim bleed** — permanently discard the printer's bleed/trim margin (TrimBox), on-device. Requires Ghostscript installed separately (`brew install ghostscript`) — see [Engine Benchmark](#engine-benchmark) for why it isn't bundled.

This project is early and honest about what's not built yet — see [Roadmap](#roadmap) for what's next.

## Install

Download the latest DMG from [Releases](../../releases), open it, and drag **PDF Tools.app** into Applications. The app isn't notarized yet, so on first launch: right-click → Open. Prefer to build it yourself? See [Building from source](#building-from-source).

## Usage

### GUI
Open **PDF Tools.app**, drag PDF files (or a folder) onto the window, pick an operation (enter a password if the file needs one), run. The result list shows done/skipped/error per file; jump to the output in Finder from there.

### CLI
```bash
swift run pdftools engines
swift run pdftools unlock [--password PASSWORD] [--out DIR] file.pdf...
swift run pdftools trim [--out DIR] file.pdf...
```

## Engine Benchmark

Measured 2026-09-07 on Apple Silicon, unlocking a 593 MB / 144-page, AES-128 owner-encrypted PDF:

| Engine | Time | Result |
|---|---|---|
| qpdf | 3.1 s | Succeeded — PDF version and metadata preserved. **Primary engine.** |
| pdfcpu | 5.9 s | Succeeded — overwrites Producer/CreationDate, bumps the PDF version to 1.7. **Fallback engine.** |
| pypdf | 1.6 s | Succeeded, but requires a Python runtime — ruled out. |
| Apple PDFKit (built-in) | 28 s | Output was **still encrypted** — ruled out. |
| fadeltd/pdfunlock (Go) | — | Prompts for a password on the TTY, never tries an empty password, can't be driven from an app — ruled out. |

qpdf and pdfcpu are compiled as universal (arm64+x86_64) static binaries by `packaging/build-engines.sh` and shipped inside the app bundle — no runtime dependency, no network call at unlock time.

**Trim bleed** uses Ghostscript (`gs -dUseTrimBox -sDEVICE=pdfwrite`), which is **not bundled** and never will be: Ghostscript is AGPL-3.0-or-later, while this project is MIT and the two engines above are Apache-2.0. Bundling an AGPL binary would pull the whole distribution under AGPL. Instead, Trim looks for a `gs` the user already installed (Homebrew); if it's missing, the operation is cleanly disabled with an install hint instead of failing silently. A measured caveat: Ghostscript's trim only *repositions* content to the new page origin, it does not clip geometry that straddles the old trim boundary (e.g. a full-bleed image or a guide line spanning the page) — so the app verifies every trim output by rendering past the declared page box and rejects (or flags) any output that still shows leftover ink, rather than trusting the box metadata.

## Roadmap

- **v0.2** — Merge, Split, reorder/rotate/delete pages, Remove watermark, PDF → image (PNG/JPEG/HEIC/WebP)
- **v0.3** — Compress, add watermark/page numbers, Encrypt, add/extract QR codes
- **v0.4** — Linearize, repair/validate, extract images, edit bookmarks, extract text/metadata
- **v1.0** — Deep OCR (layout- and formula-aware, benchmarked against OmniDocBench)

## Building from source

Requirements: macOS 14+, Xcode 26 / Swift 6.3. Building the engines additionally needs `cmake`, `go`, `gh`.

```bash
./packaging/build-engines.sh   # builds qpdf + pdfcpu into vendor/bin/ (needs internet, repeatable)
swift build                    # universal build: swift build --arch arm64 --arch x86_64
swift test                     # 16 tests, Tests/PDFToolsCoreTests/ (trim tests skip if gs isn't installed)
./packaging/build.sh           # produces build/PDF Tools.app (set SIGN_IDENTITY for a Developer ID signature)
```

No external SwiftPM dependencies. The only third-party code in this project is the two vendored engine binaries described below.

## Third-party components

qpdf and pdfcpu ship as compiled binaries inside the app bundle (qpdf statically links libjpeg-turbo). Full component list, versions, upstream sources and license texts: [THIRD_PARTY.md](THIRD_PARTY.md).

## License

MIT — see [LICENSE](LICENSE).
