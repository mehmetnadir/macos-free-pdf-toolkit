[Türkçe](README.tr.md)

# PDF Tools

[![CI](https://github.com/mehmetnadir/macos-free-pdf-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/mehmetnadir/macos-free-pdf-toolkit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

A free, local, native macOS PDF toolbox — no upload, no subscription.

![PDF Tools with five files loaded: the file list on top, the grid of action cards below](docs/screenshot.png)

## Why this exists

Most PDF operations people need are one-off and boring: unlock a file, drop the
printer's bleed margin, merge a folder, make a scan searchable. The common
answer is a web uploader with a subscription, or a suite you install and then
fight with. Neither is a good trade for a file you would rather not upload at
all.

So this is a small Mac app instead:

- **Local.** Files never leave the machine. There is no account, no network call
  during an operation, no telemetry.
- **No install ceremony.** The engines it needs (qpdf, pdfcpu) are compiled as
  universal static binaries and live inside the app bundle. One optional
  external tool remains — see [Engines & licensing](#engines--licensing).
- **Every operation verifies its own output.** The engine saying "done" is not
  evidence. Unlock re-opens the file and rejects it if it is still encrypted;
  Merge counts pages against the sum of the inputs; Add QR scans the QR back
  and fails if it does not decode; Trim renders past the declared page box and
  looks for leftover ink. When verification fails, the output is deleted rather
  than handed over.
- **Honest results.** Where an operation costs you something — a lost text
  layer, lost links, a faint trace along an edge — the result line says so
  instead of quietly succeeding.

The app is early. What is not built yet is listed in the
[Roadmap](#roadmap), not hidden.

## Getting started

### Install

Download the latest DMG from [Releases](../../releases), open it, and drag
**PDF Tools.app** into Applications.

The app is **not notarized yet**, so macOS will refuse the first double-click.
How you get past that depends on the version. On macOS 14, right-click the app →
**Open** → **Open** once. On macOS 15 and later that shortcut no longer works —
open **System Settings ▸ Privacy & Security**, scroll down to the message naming
PDF Tools, and press **Open Anyway**. Either way it launches normally from then
on. This is a real inconvenience, not a formality; it goes away when
notarization lands.

### First run

Open **PDF Tools.app**. With nothing loaded you get the drop area, a
**Choose Files…** button, a **Create Blank PDF…** button, and a dimmed list of
what the app can do:

![Empty state: drop area, Choose Files, Create Blank PDF, and the dimmed capability list](docs/empty-state.png)

Drop PDF files (or a whole folder) onto the window. The app inspects each file
and shows one action card per operation. Cards that actually apply are enabled
and one is auto-suggested — a locked file suggests **Unlock**, two clean files
suggest **Merge**. The rest stay dimmed **with the reason why**: Unlock reads
"already unlocked" when nothing is encrypted, Trim Bleed reads "No bleed margin
found" when there is no bleed to remove. Tap a card to pick a different
operation, fill in whatever it needs (a password, a QR payload, a watermark
text), and run.

The file list is sized to show every file at once — up to eight rows — instead
of scrolling inside a fixed frame, and the window's minimum height grows with it
(46 pt per row), so rows cannot be squeezed out of sight. Launched with a clean
preference domain, the window opens at 640×716 for one to five files and 640×854
for eight or more; beyond eight rows the list itself scrolls. The interface is in
English.

Keyboard: **⌘N** new blank PDF, **⌘O** add files, **⇧⌘⌫** clear the list.

### Building from source

Requirements: macOS 14+, Xcode 26 / Swift 6.3. Building the engines
additionally needs `cmake`, `go`, `gh`.

```bash
./packaging/build-engines.sh   # builds qpdf + pdfcpu into vendor/bin/ (needs internet, repeatable)
swift build                    # universal build: swift build --arch arm64 --arch x86_64
swift test                     # 160 tests, Tests/PDFToolsCoreTests/
./packaging/build.sh           # produces build/PDF Tools.app (set SIGN_IDENTITY for a Developer ID signature)
```

No external SwiftPM dependencies. The only third-party code in the project is
the two vendored engine binaries.

## Operations

Every operation below is available both as an action card in the app and as a
`pdftools` subcommand. The option names and values are the ones the app
actually shows; defaults are marked.

### Security & access

#### Unlock

Removes the user/owner password and any copy/print restrictions, entirely
on-device. qpdf is the primary engine, pdfcpu the fallback. The output is
re-opened after writing and rejected if it is still encrypted — a "successful"
run that produced an encrypted file counts as a failure.

Options: the password, if the file needs one to open at all.

```bash
pdftools unlock [--password PASSWORD] [--out DIR] <file.pdf|folder>...
```

#### Encrypt

Password-protects the file with 256-bit AES via qpdf. A user password (to open)
and an optional separate owner password (to change permissions) are supported.
40-bit and 128-bit encryption are considered insecure and are deliberately not
offered.

| Option | Values | Default |
|---|---|---|
| Permissions | Everything allowed · Printing disabled · Copying disabled · Printing + copying disabled | Everything allowed |

```bash
pdftools encrypt [--password PASSWORD] [--owner-password PASSWORD] \
                 [--permissions all|noprint|nocopy|readonly] [--out DIR] <file.pdf|folder>...
```

### Print preparation

#### Trim Bleed

Permanently discards the printer's bleed/trim margin — the TrimBox and
everything outside it — so the file matches the finished page. The card is only
enabled for files that actually declare a bleed.

**This no longer requires Ghostscript.** The default engine is CoreGraphics,
which is part of macOS. Measured on a real book page with a 5 mm bleed:

| Engine | Ink left outside the trim box | Pixel difference inside the trim box | Links / form fields kept |
|---|---|---|---|
| CoreGraphics (default) | 0.00% | 0.03/255 | no |
| Ghostscript | 0.00% | 4.02/255 | yes |
| pdfcpu | 11.65% | — | — (ruled out) |

CoreGraphics is the more faithful of the two working engines inside the trim
box: Ghostscript re-encodes the images on the way through (`/prepress`), which
shows up as a 4.02/255 difference where CoreGraphics leaves 0.03/255. Extracted
text is byte-identical either way.

There is a cost, and the app does not hide it. Because CoreGraphics re-draws
the page, it cannot carry annotations across: on a real 12-page file, **all 24
annotations (links and form fields) were lost with CoreGraphics and all 24 were
kept with Ghostscript**. So the engine is chosen **per file**:

- The file has no annotations → CoreGraphics, which is better in every measured
  respect.
- The file has annotations and Ghostscript is installed → Ghostscript, to keep
  them.
- The file has annotations and Ghostscript is missing → the trim still runs, and
  the result line states how many links or form fields could not be kept, with
  the install hint.

Verification renders past the declared page box and measures leftover ink;
an output that still shows bleed is deleted rather than accepted, and a faint
trace along the edges is reported as such. An inconsistent TrimBox across pages
is reported too. Progress is per page.

```bash
pdftools trim [--out DIR] <file.pdf|folder>...
```

#### Blank PDF

Creates an empty PDF with the number of pages you ask for. This is **not** an
action card — it has no input file — so it lives on the empty state
(**Create Blank PDF…**) and in **File ▸ New Blank PDF…** (**⌘N**).

![New Blank PDF sheet: page count, size, orientation, and a live measurement summary](docs/blank-pdf.png)

| Option | Values | Default |
|---|---|---|
| Pages | 1–5000 | 1 |
| Size | A4 · A5 · A3 · Letter · Legal · Tabloid · Custom… (width × height in mm) | A4 |
| Orientation | Portrait · Landscape | Portrait |

The sheet shows a live measurement summary of what you are about to get. Point
sizes are derived from millimetres in one place (`mm × 72 / 25.4`) rather than
hardcoded per paper size.

The file is written to a hidden temporary file first, then re-opened to check
the page count and the first page's MediaBox; if either does not match, nothing
is left behind. On the CLI an existing file is never silently overwritten, and
`--out` accepts either a `.pdf` path or a folder (without it you get `Blank.pdf`
in the current directory). The finished PDF is added to the app's file list, so you can immediately run
another operation on it — number the pages, add a watermark, merge it into
something else.

```bash
pdftools blank [--pages 1] [--size a4|a5|a3|letter|legal|tabloid] \
               [--width MM --height MM] [--landscape] [--out FILE.pdf|DIR]
```

### Pages & structure

#### Organize Pages

Reorder, rotate, and delete pages in one pass. Tapping the card opens a page
grid: drag to reorder, click to rotate or delete, undo if you change your mind.

![Organize Pages sheet: a thumbnail grid of the book's pages with rotate, delete and Select All, and a count of pending changes](docs/page-grid.png)

What you confirm becomes a single qpdf invocation, and the result is then
verified page by page against that exact plan — order, rotation, page count.

Thumbnails come from a persistent on-disk cache: the first 12 take ~2.75 s cold
and ~0.008 s when the same book is reopened later.

```bash
pdftools pageedit [--order 3,1,2] [--rotate 1:90,4:180] [--out DIR] <file.pdf>...
```

#### Merge

Combines every file in the list into one PDF, in the order you dropped them.
This is the one operation that consumes the whole list at once rather than
running per file. The output's page count is checked against the sum of the
inputs; on a mismatch the output is deleted and the run reports a failure.

```bash
pdftools merge [--out DIR] <file.pdf>...
```

#### Split

Breaks a PDF into parts.

| Option | Values | Default |
|---|---|---|
| Mode | Every page separate · N-page chunks · Split in half | Every page separate |
| Chunk Size (N-page chunks) | 2 · 5 · 10 · 20 · 50 pages | 10 pages |

Verification adds up the pages across the produced parts and compares with the
source; a mismatch, or any zero-page part, deletes the output.

```bash
pdftools split [--mode each|n:10|half] [--out DIR] <file.pdf|folder>...
```

#### Bookmarks

Exports the outline tree to a JSON file you can edit by hand, and imports it
back.

| Option | Values | Default |
|---|---|---|
| Mode | Export — save bookmarks to a JSON file · Import — apply bookmarks from a JSON file | Export |

```bash
pdftools bookmarks [--mode export|import] [--file bookmarks.json] [--out DIR] <file.pdf|folder>...
```

### Size & delivery

#### Compress

Three levels, because the honest answer differs by an order of magnitude.
Measured on an image-heavy book: **Light ≈ 9%**, **Strong ≈ 39%**,
**Rasterize ≈ 91%**.

| Option | Values | Default |
|---|---|---|
| Level | Light (lossless) · Strong (needs Ghostscript) · Rasterize (text layer is lost) | Light |
| Resolution (Rasterize) | 72 dpi — smallest file · 150 dpi — for screen · 200 dpi — balanced · 300 dpi — for print | 150 dpi |
| Quality (Rasterize) | Low · Medium · High | Medium |

Light is lossless via the bundled qpdf. Strong re-encodes the images too and is
the **only** thing left in the app that needs Ghostscript; if it is missing you
get the guided setup page described in
[Engines & licensing](#engines--licensing), not a dead end. Rasterize turns
every page into an image — the text layer is gone, and the result line says so
rather than letting you discover it later.

For Light and Strong, verification checks that real text present on page 1 of
the source is still present in the output.

```bash
pdftools compress [--level light|strong|raster] [--dpi 150] [--quality 0.7] \
                  [--out DIR] <file.pdf|folder>...
```

#### Optimize for Web

`qpdf --linearize`, so a large book opens page by page over the network instead
of downloading whole before the first page appears.

```bash
pdftools linearize [--out DIR] <file.pdf|folder>...
```

#### Repair

Diagnoses structural problems with `qpdf --check` and rewrites the file **only
if something is actually wrong**. A clean file is reported as clean rather than
needlessly rewritten — rewriting a healthy PDF is a change you did not ask for.

```bash
pdftools repair [--out DIR] <file.pdf|folder>...
```

### Text & recognition

#### Extract Text

Writes the existing text layer to a `.txt` file.

| Option | Values | Default |
|---|---|---|
| Layout | Plain — no page markers · Page breaks — marks where each page starts | Plain |

A scanned book has no text layer, and this operation says so — it reports that
OCR is needed instead of silently producing an empty file.

```bash
pdftools extracttext [--layout plain|pages] [--out DIR] <file.pdf|folder>...
```

#### OCR

Reads text out of scanned pages with the built-in Vision framework: no model
download, no API key, no network — about a second per page.

| Option | Values | Default |
|---|---|---|
| Language | Turkish · English · Automatic (TR + EN) | Turkish |
| Resolution | 150 dpi — faster · 200 dpi — recommended · 300 dpi — most accurate | 200 dpi |
| Quality | Accurate (slower) · Fast (less accurate) | Accurate |

Turkish is supported, and where it is imperfect the result says so: the dotted
capital İ is sometimes read as I, measured on a real textbook page, so the note
tells you to check critical text. If Turkish support is not installed on the
Mac at all, the app reports that the text was read with an English recognizer
rather than pretending it was Turkish.

```bash
pdftools ocr [--language tr|en|auto] [--dpi 200] [--level accurate|fast] \
             [--out DIR] <file.pdf|folder>...
```

#### Make Searchable

Puts an invisible text layer over a scanned page, so the scan stays a scan but
the text becomes selectable and searchable.

| Option | Values | Default |
|---|---|---|
| Language | Turkish · English · Automatic (TR + EN) | Turkish |
| Resolution | 150 dpi — faster · 200 dpi — recommended · 300 dpi — most accurate | 200 dpi |

Two checks before the file is accepted: the page image is unchanged (verified by
pixel comparison), and the text can actually be read back out of the output.

```bash
pdftools searchable [--language tr|en|auto] [--dpi 200] [--out DIR] <file.pdf|folder>...
```

### Extract & export

#### PDF to Images

Exports every page as an image, entirely on-device with the built-in
CoreGraphics/ImageIO — no subprocess.

| Option | Values | Default |
|---|---|---|
| Format | PNG — lossless, larger files · JPEG — smaller files, some quality loss · HEIC — smallest files, needs newer viewers | PNG |
| Resolution | 72 dpi — web preview · 150 dpi — for screen · 300 dpi — for print · 600 dpi — high-res print | 150 dpi |

HEIC is offered **only** where the system can actually write it — checked at
runtime, not assumed. Verification compares the number of files produced with
the page count, so a page that failed to render cannot pass as a success.

```bash
pdftools image [--format png|jpeg|heic] [--dpi 150] [--out DIR] <file.pdf|folder>...
```

#### Extract Embedded Images

Pulls the images embedded in the pages out into their own files.

| Option | Values | Default |
|---|---|---|
| Minimum Size | All · Larger than 10,000 px | Larger than 10,000 px |

The default filter exists because books are full of tiny decorative fragments;
switch to All when you want literally everything.

```bash
pdftools extractimages [--min-size 10000] [--out DIR] <file.pdf|folder>...
```

#### Extract QR

Lists every QR code in the book as `page`/`content` lines in a text file.

| Option | Values | Default |
|---|---|---|
| Resolution | 150 dpi — faster · 200 dpi — recommended · 300 dpi — most accurate | 200 dpi |

200 dpi is the default for a measured reason: on a real textbook, detection at
100 dpi finds nothing at all, which is indistinguishable from "this book has no
QR codes". The report always states how many pages were scanned, so an empty
result can be read as an empty result.

```bash
pdftools qrextract [--dpi 200] [--out DIR] <file.pdf|folder>...
```

### Marks

#### Add QR

Draws a QR code onto the pages without rasterising them — the text stays text.

| Option | Values | Default |
|---|---|---|
| Content | the payload text | — (required) |
| Position | Bottom right · Bottom left · Top right · Top left | Bottom right |
| Size | Small · Medium · Large | Medium |
| Pages | All pages · First page only | All pages |

The output is scanned back before it is accepted, so a QR that does not decode
is a failure, not a silent success.

```bash
pdftools qradd --content TEXT [--position br|bl|tr|tl] [--size small|medium|large] \
               [--pages all|first] [--out DIR] <file.pdf|folder>...
```

#### Add Watermark

Draws a custom text watermark on every page, with CoreText.

| Option | Values | Default |
|---|---|---|
| Text | the watermark text | — (required) |
| Position | Center (diagonal) · Header · Footer | Center (diagonal) |
| Opacity | 15% — subtle · 30% — noticeable · 50% — bold | 15% |
| Font Size | 24 pt — small · 36 pt — medium · 48 pt — large | 36 pt |
| Color | Gray · Red · Blue | Gray |

CoreText rather than pdfcpu, for a measured reason: in testing pdfcpu silently
truncated header and footer text ("TEST HEADER" became "TEST HEA").

```bash
pdftools watermarkadd --text TEXT [--position center|header|footer] [--opacity 0.15] \
                      [--font-size 36] [--color gray|red|blue] [--out DIR] <file.pdf|folder>...
```

#### Remove Watermark (experimental)

Finds the object that repeats on nearly every page and empties it. On a real
144-page book it found the stamp on 143 pages and removed it in 1.7 s; the text
went from 143 occurrences to none. Marked experimental because "the thing that
repeats everywhere" is a heuristic, not a definition.

```bash
pdftools watermarkremove [--out DIR] <file.pdf|folder>...
```

#### Add Page Numbers

Draws a page number on every page, with CoreText.

| Option | Values | Default |
|---|---|---|
| Position | Bottom center · Bottom right · Bottom left · Top center · Top right | Bottom center |
| Start | From 1 (cover included) · Cover not counted | From 1 |
| Format | Number only (e.g. "5") · Number and total (e.g. "5 / 120") | Number and total |

The "cover not counted" case is the second reason pdfcpu was ruled out for
drawing: its page-number macro cannot express a cover page that is not counted.

```bash
pdftools pagenumber [--position footer-center|footer-right|footer-left|header-center|header-right] \
                    [--start-at 1] [--format plain|ofN] [--out DIR] <file.pdf|folder>...
```

## How results are handled

Where the output goes, what it is called, and how you find it are part of the
operation, not an afterthought.

**Where it goes.** A single output is written next to the original, with no
extra folder. Multiple outputs get a `PDF Tools — <Operation>` folder next to
the original. The count is of top-level outputs, which means an operation that
already produces a folder is not wrapped in a second one: splitting one file
gives one `_parts/` folder and no wrapper, splitting three files gives three and
does get a wrapper.

If the source folder is not writable — a read-only volume, a quarantined
download — the output lands on the Desktop **and the app says so**. Writing
somewhere else silently leaves you hunting for your file. If a run ends up
producing nothing at all, the batch folder it opened is removed again rather
than left behind empty.

**Naming does not chain.** Suffixes accumulate into unreadable names
(`book_compressed_watermarked_numbered.pdf`), so known suffixes are stripped
before the new one is added: numbering the pages of `book_compressed.pdf`
produces **`book_numbered.pdf`**, not `book_compressed_numbered.pdf`. The
deliberate trade-off is that the name describes the last operation, not the
whole history — the file content of course carries all of them. Nothing is ever
overwritten: a collision becomes `book_numbered 2.pdf`, then `3`, and so on.

**Progress.** Each file shows its own progress, and where an operation works
page by page the bar moves page by page — both trim engines report real per-page
progress rather than just 0 and 1. A batch run adds an overall bar at the
bottom: bar, "3 of 20", percentage.

**Finding the output.** When the run finishes, Finder is revealed **only if the
app is still in the foreground**. If you moved on to something else, the Dock
icon bounces once and the "Show" button in the result row waits for you — your
focus is not stolen, and no notification permission is requested for a tool this
small.

Per file, the result list shows done / skipped / error, with the note the
operation attached: how much smaller, how many QR codes were found, that the
text layer is gone, that links could not be kept.

## Command line

The same core drives a CLI. From a source checkout, prefix with `swift run`
(`swift run pdftools engines`); inside the app bundle the binary is `pdftools`.

```
pdftools unlock [--password PASSWORD] [--out DIR] <file.pdf|folder>...
pdftools trim [--out DIR] <file.pdf|folder>...
pdftools merge [--out DIR] <file.pdf>...
pdftools split [--mode each|n:10|half] [--out DIR] <file.pdf|folder>...
pdftools image [--format png|jpeg|heic] [--dpi 150] [--out DIR] <file.pdf|folder>...
pdftools pageedit [--order 3,1,2] [--rotate 1:90,4:180] [--out DIR] <file.pdf>...
pdftools compress [--level light|strong|raster] [--dpi 150] [--quality 0.7]
                  [--out DIR] <file.pdf|folder>...
pdftools encrypt [--password PASSWORD] [--owner-password PASSWORD]
                 [--permissions all|noprint|nocopy|readonly] [--out DIR] <file.pdf|folder>...
pdftools linearize [--out DIR] <file.pdf|folder>...
pdftools repair [--out DIR] <file.pdf|folder>...
pdftools extractimages [--min-size 10000] [--out DIR] <file.pdf|folder>...
pdftools extracttext [--layout plain|pages] [--out DIR] <file.pdf|folder>...
pdftools qradd --content TEXT [--position br|bl|tr|tl] [--size small|medium|large]
               [--pages all|first] [--out DIR] <file.pdf|folder>...
pdftools qrextract [--dpi 200] [--out DIR] <file.pdf|folder>...
pdftools ocr [--language tr|en|auto] [--dpi 200] [--level accurate|fast]
             [--out DIR] <file.pdf|folder>...
pdftools searchable [--language tr|en|auto] [--dpi 200] [--out DIR] <file.pdf|folder>...
pdftools watermarkremove [--out DIR] <file.pdf|folder>...   (experimental)
pdftools watermarkadd --text TEXT [--position center|header|footer]
                      [--opacity 0.15] [--font-size 36] [--color gray|red|blue]
                      [--out DIR] <file.pdf|folder>...
pdftools pagenumber [--position footer-center|footer-right|footer-left|header-center|header-right]
                    [--start-at 1] [--format plain|ofN] [--out DIR] <file.pdf|folder>...
pdftools bookmarks [--mode export|import] [--file bookmarks.json]
                   [--out DIR] <file.pdf|folder>...
pdftools blank [--pages 1] [--size a4|a5|a3|letter|legal|tabloid]
               [--width MM --height MM] [--landscape] [--out FILE.pdf|DIR]
pdftools engines
```

Anywhere a `<file.pdf|folder>` is accepted you can pass a folder and every PDF
in it is processed. `pdftools engines` reports which engines were found.

## Engines & licensing

**Bundled.** qpdf (primary) and pdfcpu (fallback) are compiled as universal
(arm64+x86_64) static binaries by `packaging/build-engines.sh` and shipped
inside the app bundle — no runtime dependency, no network call. qpdf statically
links libjpeg-turbo. Both are Apache-2.0, which is compatible with this
project's MIT licence. Full component list, versions, upstream sources and
licence texts: [THIRD_PARTY.md](THIRD_PARTY.md).

**Built into macOS.** CoreGraphics/ImageIO (page rendering, image export,
default bleed trimming), CoreText (watermarks and page numbers), Vision (OCR).
No model download, no API key.

**Not bundled, and never will be: Ghostscript.** It is AGPL-3.0-or-later, and
shipping an AGPL binary inside the app would pull the whole distribution under
the AGPL. So the app looks for a `gs` the user installed themselves. As of the
CoreGraphics trim engine, exactly two things want it: the **Strong** compression
level, and preserving annotations while trimming an annotated file.

Missing Ghostscript is not a dead end. The app shows a guided setup page that
names what is missing, explains why it is not bundled, offers the install
command with a copy button, and links the official download page for people
without Homebrew:

![Ghostscript setup page: what is missing, why it is not bundled, a copyable brew command, and Check Again](docs/setup-ghostscript.png)

**Check Again** re-runs the lookup in place — you do not have to restart the
app after installing.

### Engine benchmark: unlocking

Measured 2026-09-07 on Apple Silicon, unlocking a 593 MB / 144-page, AES-128
owner-encrypted PDF:

| Engine | Time | Result |
|---|---|---|
| qpdf | 3.1 s | Succeeded — PDF version and metadata preserved. **Primary engine.** |
| pdfcpu | 5.9 s | Succeeded — overwrites Producer/CreationDate, bumps the PDF version to 1.7. **Fallback engine.** |
| pypdf | 1.6 s | Succeeded, but requires a Python runtime — ruled out. |
| Apple PDFKit (built-in) | 28 s | Output was **still encrypted** — ruled out. |
| fadeltd/pdfunlock (Go) | — | Prompts for a password on the TTY, never tries an empty password, can't be driven from an app — ruled out. |

The trim-engine comparison is in [Trim Bleed](#trim-bleed).

## Testing

`swift test` runs **160 tests** (2 skip on a machine without Ghostscript
installed).

The tests follow the same rule as the app: **the engine saying "done" is not
evidence.** A test re-opens the produced file and measures it — page counts,
rotation per page, pixels rendered past the page box, text read back out of the
output, a QR decoded from the rendered page, whether the output is still
encrypted.

Verification gates are themselves proved by mutation: the gate is deliberately
broken (write one page too few, skip the trim, leave the file encrypted), the
suite is watched to go red, and the break is reverted. A gate that has never
been seen to fail is not known to work. One contract test pins that every
operation's output suffix is known to the namer, so the chained-name behaviour
described in [How results are handled](#how-results-are-handled) cannot silently
regress when a new operation is added.

## Roadmap

- **Done** — Unlock, Encrypt, Trim Bleed, Blank PDF, Organize Pages, Merge,
  Split, Bookmarks, Compress, Optimize for Web, Repair, Extract Text, OCR, Make
  Searchable, PDF to Images, Extract Embedded Images, Extract QR, Add QR, Add
  Watermark, Remove Watermark (experimental), Add Page Numbers
- **Next** — notarization, so the first launch needs neither right-click → Open
  nor the Privacy & Security detour
- **Later** — layout- and formula-aware document OCR, benchmarked against
  OmniDocBench, for textbooks with equations and complex page structure

## License

MIT — see [LICENSE](LICENSE).
