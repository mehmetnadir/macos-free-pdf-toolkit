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
      Text("New Blank PDF").font(.title3.weight(.semibold))

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
        GridRow {
          Text("Pages")
          HStack(spacing: 8) {
            TextField("", value: $pageCount, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 70)
            Stepper("", value: $pageCount, in: 1...5000).labelsHidden()
          }
        }
        GridRow {
          Text("Size")
          Picker("", selection: $selectedName) {
            ForEach(PageSize.standard, id: \.name) { size in
              Text(size.name).tag(size.name)
            }
            Divider()
            Text("Custom…").tag(Self.customName)
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
          Text("Orientation")
          Picker("", selection: $isLandscape) {
            Text("Portrait").tag(false)
            Text("Landscape").tag(true)
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
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Create…") { onCreate(pageCount, chosenSize) }
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
    guard isValid else { return "Enter at least 1 page and a size larger than zero" }
    let size = chosenSize
    let widthMM = size.width * 25.4 / 72
    let heightMM = size.height * 25.4 / 72
    let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
    return String(
      format: "%@ · %.0f × %.0f mm · %.0f × %.0f pt",
      pages, widthMM, heightMM, size.width, size.height)
  }
}
