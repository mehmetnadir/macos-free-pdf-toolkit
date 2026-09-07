# Third-Party Components

PDF Tools itself is MIT-licensed (see [LICENSE](LICENSE)). It bundles two compiled command-line
engines inside the app, which carry their own licenses. This file lists everything distributed
with the app binary, not build/dev-only tooling.

---

## 1. qpdf

- **Component:** qpdf
- **Version:** 12.4.1
- **Upstream:** https://github.com/qpdf/qpdf
- **Distributed as:** `Contents/Resources/bin/qpdf` inside the app bundle (statically linked, universal arm64+x86_64 binary)
- **License:** Apache License 2.0 (SPDX: `Apache-2.0`)
- **Full license text:** https://github.com/qpdf/qpdf/blob/v12.4.1/LICENSE.txt
- **Attribution / NOTICE:** Apache-2.0 requires that a copy of the license accompany any
  distribution and that any `NOTICE` file provided by the licensor be preserved in derivative
  distributions. qpdf's repository does not ship a `NOTICE` file at v12.4.1; the license text
  linked above is the complete attribution requirement. No modifications were made to qpdf's
  source in this project.

## 2. pdfcpu

- **Component:** pdfcpu
- **Version:** v0.15.0
- **Upstream:** https://github.com/pdfcpu/pdfcpu
- **Distributed as:** `Contents/Resources/bin/pdfcpu` inside the app bundle (universal arm64+x86_64 binary, `CGO_ENABLED=0`)
- **License:** Apache License 2.0 (SPDX: `Apache-2.0`)
- **Full license text:** https://github.com/pdfcpu/pdfcpu/blob/v0.15.0/LICENSE.txt
- **Attribution / NOTICE:** Same Apache-2.0 obligation as above — preserve the license text with
  any distribution. pdfcpu's repository does not ship a separate `NOTICE` file at v0.15.0. No
  modifications were made to pdfcpu's source in this project.

## 3. libjpeg-turbo

- **Component:** libjpeg-turbo
- **Version:** 3.2.0
- **Upstream:** https://github.com/libjpeg-turbo/libjpeg-turbo
- **Distributed as:** statically linked into `vendor/bin/qpdf` / `Contents/Resources/bin/qpdf`
  (built with `-DENABLE_SHARED=0 -DENABLE_STATIC=1 -DWITH_TURBOJPEG=0`, JPEG support for qpdf's
  image handling only — not exposed as a separate binary)
- **License:** dual-licensed, **not** a single SPDX identifier:
  - IJG (Independent JPEG Group) License — applies to the libjpeg API code that qpdf links against
  - Modified (3-clause) BSD License — applies to TurboJPEG/build-system code
  - (GitHub's license detector reports this repo as "Other" for exactly this reason — it is not
    a single well-known license.)
- **Full license text:**
  - Overview: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/3.2.0/LICENSE.md
  - IJG License: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/3.2.0/README.ijg
  - Modified BSD License: included in `LICENSE.md` above
- **Attribution / NOTICE:** Not Apache-2.0, so no NOTICE-propagation duty; both the IJG License
  and the Modified BSD License require that copyright/license notices be retained and, per the
  IJG License, that the IJG `README` be included when redistributing modified libjpeg-turbo
  source (not applicable here — the source is unmodified and only a compiled static library is
  linked in). No modifications were made to libjpeg-turbo's source in this project.

---

This repository contains source code only; the vendored binaries are compiled from upstream
source via `packaging/build-engines.sh`. (Bu depo yalnızca kaynak kodu içerir; ikililer
`packaging/build-engines.sh` ile upstream kaynaktan derlenir.)
