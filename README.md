[Türkçe](README.tr.md)

# PDF Tools

[![CI](https://github.com/mehmetnadir/macos-free-pdf-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/mehmetnadir/macos-free-pdf-toolkit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

A free, local, native macOS PDF toolbox — no upload, no subscription.

![PDF Tools](docs/screenshot.png)

## Features

- **Unlock** — remove owner/user passwords and restrictions from encrypted PDFs, entirely on-device.
- **Trim bleed** — permanently discard the printer's bleed/trim margin (TrimBox), on-device. Requires Ghostscript installed separately (`brew install ghostscript`) — see [Engine Benchmark](#engine-benchmark) for why it isn't bundled.
- **Merge** — combine every file in your list into one PDF, in the order you dropped them.
- **Split** — break a PDF into parts: one file per page, fixed-size chunks (2/5/10/20/50 pages), or an even split in two.
- **PDF → image** — export every page as PNG, JPEG, or HEIC, at 72–600 dpi, entirely on-device (built-in CoreGraphics/ImageIO, no subprocess). HEIC is offered only where the system can actually write it — checked at runtime, not assumed.
- **Reorder / rotate / delete pages** — a page grid (drag to reorder, click to rotate or delete, with undo) turns your plan into a single qpdf pass, then verifies the result page-by-page against that exact plan. Thumbnails come from a persistent on-disk cache — the first 12 thumbnails take ~2.75 s cold, ~0.008 s on a later reopen of the same book.

- **Compress** — three levels, because the honest answer differs by an order of magnitude. Lossless with the bundled qpdf (about 9% on an image-heavy book), stronger with Ghostscript if you have it (about 39%), or rasterise every page (about 91%, and the text layer is gone — the app says so on the result).
- **Encrypt** — 256-bit AES via qpdf, user and owner passwords, optional print/copy restrictions. 40- and 128-bit are considered insecure and are not offered.
- **Add QR** — draw a QR code on every page or just the first, in any corner, without rasterising the page. The output is scanned back before it is accepted, so a QR that does not decode is a failure, not a silent success.
- **Extract QR** — list every QR in a book as `page`/`content` lines. Defaults to 200 dpi: measured on a real textbook, detection finds nothing at all at 100 dpi, which is indistinguishable from "this book has no QR codes". The report always states how many pages were scanned.
- **Prepare for fast web view** — `qpdf --linearize`, so a large book opens page by page over the network.
- **Repair** — diagnose with `qpdf --check` and rewrite only if something is actually wrong; a clean file is reported as clean rather than needlessly rewritten.
- **Extract images** — pull embedded images out of a book.
- **Extract text** — the text layer as a `.txt` file. A scanned book is reported as needing OCR rather than silently producing an empty file.

- **OCR** — read text out of a scanned book with the built-in Vision framework: no model download, no API key, about a second per page. Turkish is supported, and the result says so where it matters: the dotted capital İ is sometimes read as I, measured on a real textbook page, so the note tells you to check critical text.
- **Make searchable** — put an invisible text layer over a scanned page. The image is untouched (verified by pixel comparison) and the text becomes selectable and searchable, checked by reading it back before the file is accepted.
- **Add watermark** and **Add page numbers** — drawn with CoreText rather than pdfcpu, because pdfcpu silently truncated header and footer text in measurement ("TEST HEADER" became "TEST HEA") and its page-number macro cannot express a cover page that is not counted.
- **Bookmarks** — export the outline to JSON, edit it, import it back.
- **Remove watermark** (experimental) — find the object that repeats on nearly every page and empty it. On a real 144-page book it found the stamp on 143 pages and removed it in 1.7 s; the text went from 143 occurrences to none.

This project is early and honest about what's not built yet — see [Roadmap](#roadmap) for what's next.

## Install

Download the latest DMG from [Releases](../../releases), open it, and drag **PDF Tools.app** into Applications. The app isn't notarized yet, so on first launch: right-click → Open. Prefer to build it yourself? See [Building from source](#building-from-source).

## Usage

### GUI
Open **PDF Tools.app** and drop PDF files (or a folder) onto the window. The app inspects them and shows an action card per operation — the ones that actually apply are enabled and one is auto-suggested (e.g. a locked file suggests Unlock, two clean files suggest Merge); the rest stay dimmed with the reason why (e.g. Unlock stays dim as "already unlocked" if nothing's encrypted). Tap a card to pick a different operation, enter a password if needed, run. The result list shows done/skipped/error per file; jump to the output in Finder from there.

### CLI
```bash
swift run pdftools engines
swift run pdftools unlock [--password PASSWORD] [--out DIR] file.pdf...
swift run pdftools trim [--out DIR] file.pdf...
swift run pdftools merge [--out DIR] file.pdf...
swift run pdftools split [--mode each|n:10|half] [--out DIR] file.pdf...
swift run pdftools image [--format png|jpeg|heic] [--dpi 150] [--out DIR] file.pdf...
swift run pdftools pageedit [--order 3,1,2] [--rotate 1:90,4:180] [--out DIR] file.pdf...
swift run pdftools compress [--level light|strong|raster] [--dpi 150] [--quality 0.7] [--out DIR] file.pdf...
swift run pdftools encrypt [--password PASSWORD] [--owner-password PASSWORD] [--permissions all|noprint|nocopy|readonly] [--out DIR] file.pdf...
swift run pdftools qradd --content TEXT [--position br|bl|tr|tl] [--size small|medium|large] [--pages all|first] [--out DIR] file.pdf...
swift run pdftools qrextract [--dpi 200] [--out DIR] file.pdf...
swift run pdftools linearize [--out DIR] file.pdf...
swift run pdftools repair [--out DIR] file.pdf...
swift run pdftools extractimages [--min-size 10000] [--out DIR] file.pdf...
swift run pdftools extracttext [--layout plain|pages] [--out DIR] file.pdf...
swift run pdftools ocr [--language tr|en|auto] [--dpi 200] [--level accurate|fast] [--out DIR] file.pdf...
swift run pdftools searchable [--language tr|en|auto] [--dpi 200] [--out DIR] file.pdf...
swift run pdftools watermarkadd --text TEXT [--position center|header|footer] [--out DIR] file.pdf...
swift run pdftools watermarkremove [--out DIR] file.pdf...
swift run pdftools pagenumber [--position footer-center|...] [--start-at 1] [--format plain|ofN] [--out DIR] file.pdf...
swift run pdftools bookmarks [--mode export|import] [--file outline.json] [--out DIR] file.pdf...
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

- **Done** — Unlock, Trim bleed, Merge, Split, PDF → image, Reorder/rotate/delete pages, Compress, Encrypt, Add/Extract QR, Linearize, Repair, Extract images, Extract text, OCR, Make searchable, Add watermark, Add page numbers, Bookmarks, Remove watermark (experimental)
- **Later** — Layout- and formula-aware document OCR, benchmarked against OmniDocBench, for textbooks with equations and complex page structure

## Building from source

Requirements: macOS 14+, Xcode 26 / Swift 6.3. Building the engines additionally needs `cmake`, `go`, `gh`.

```bash
./packaging/build-engines.sh   # builds qpdf + pdfcpu into vendor/bin/ (needs internet, repeatable)
swift build                    # universal build: swift build --arch arm64 --arch x86_64
swift test                     # 46 tests, Tests/PDFToolsCoreTests/ (trim tests skip if gs isn't installed)
./packaging/build.sh           # produces build/PDF Tools.app (set SIGN_IDENTITY for a Developer ID signature)
```

No external SwiftPM dependencies. The only third-party code in this project is the two vendored engine binaries described below.

## Third-party components

qpdf and pdfcpu ship as compiled binaries inside the app bundle (qpdf statically links libjpeg-turbo). Full component list, versions, upstream sources and license texts: [THIRD_PARTY.md](THIRD_PARTY.md).

## License

MIT — see [LICENSE](LICENSE).
