import PDFToolsCore
import SwiftUI

/// "Boş PDF oluştur" formu.
///
/// Bu, diğer araçlardan farklı: girdi dosyası YOK, dosya BURADA doğuyor. Bu yüzden eylem
/// kartlarına konmadı — kart "önce bir PDF ekleyin" derdi. Yeri: boş ekran + Dosya menüsü.
///
/// Ölçü hem seçilebilir hem serbest: matbaa işinde A4 dışına çıkmak olağan, ama her seferinde
/// punto hesaplatmak da kullanıcının işi değil — milimetre girilir, punto karşılığı anında
/// gösterilir (kullanıcı ne ürettiğini görsün, "oluştur"a bastıktan sonra öğrenmesin).
struct BlankPDFSheet: View {
  let onCreate: (Int, PageSize) -> Void
  let onCancel: () -> Void

  @Environment(\.locale) private var locale
  @State private var pageCount = 1
  @State private var selectedName = PageSize.a4.name
  @State private var customWidthMM = 210.0
  @State private var customHeightMM = 297.0
  @State private var isLandscape = false

  private static let customName = "Custom"

  private var chosenSize: PageSize {
    let base: PageSize
    if selectedName == Self.customName {
      base = .custom(widthMM: customWidthMM, heightMM: customHeightMM)
    } else {
      base = PageSize.standard.first { $0.name == selectedName } ?? .a4
    }
    return isLandscape ? base.landscape() : base
  }

  private var isValid: Bool {
    pageCount >= 1 && chosenSize.width > 0 && chosenSize.height > 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.tr("New Blank PDF", locale: locale)).font(.title3.weight(.semibold))

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
        GridRow {
          Text(L10n.tr("Pages", locale: locale))
          HStack(spacing: 8) {
            TextField("", value: $pageCount, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 70)
            Stepper("", value: $pageCount, in: 1...5000).labelsHidden()
          }
        }
        GridRow {
          Text(L10n.tr("Size", locale: locale))
          Picker("", selection: $selectedName) {
            ForEach(PageSize.standard, id: \.name) { size in
              Text(L10n.tr(size.name, locale: locale)).tag(size.name)
            }
            Divider()
            Text(L10n.tr("Custom…", locale: locale)).tag(Self.customName)
          }
          .labelsHidden()
          .frame(width: 170)
        }
        if selectedName == Self.customName {
          GridRow {
            Text("")
            HStack(spacing: 8) {
              TextField("", value: $customWidthMM, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 70)
              Text("×").foregroundStyle(.secondary)
              TextField("", value: $customHeightMM, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 70)
              Text("mm").foregroundStyle(.secondary)
            }
          }
        }
        GridRow {
          Text(L10n.tr("Orientation", locale: locale))
          Picker("", selection: $isLandscape) {
            Text(L10n.tr("Portrait", locale: locale)).tag(false)
            Text(L10n.tr("Landscape", locale: locale)).tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 200)
        }
      }

      Text(measurementSummary)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button(L10n.tr("Cancel", locale: locale), action: onCancel).keyboardShortcut(.cancelAction)
        Button(L10n.tr("Create…", locale: locale)) { onCreate(pageCount, chosenSize) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid)
      }
    }
    .padding(22)
    .frame(width: 420)
  }

  /// Kullanıcı ne üreteceğini ONAYLAMADAN ÖNCE görsün: sayfa sayısı + iki birimde ölçü.
  private var measurementSummary: String {
    guard isValid else {
      return L10n.tr("Enter at least 1 page and a size larger than zero", locale: locale)
    }
    let size = chosenSize
    let widthMM = size.width * 25.4 / 72
    let heightMM = size.height * 25.4 / 72
    let pages = pageCount == 1
      ? L10n.tr("1 page", locale: locale)
      : L10n.text("%d pages", locale: locale, pageCount)
    return String(
      format: "%@ · %.0f × %.0f mm · %.0f × %.0f pt",
      pages, widthMM, heightMM, size.width, size.height)
  }
}
