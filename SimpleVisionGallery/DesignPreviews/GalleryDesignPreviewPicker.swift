import SwiftUI

enum GalleryDesignDirection: String, CaseIterable, Identifiable {
    case classic, prism, cinema, archive
    static let preferenceKey = "gallery.designPreview.v1"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .classic: "photo.on.rectangle"
        case .prism: "square.stack.3d.up"
        case .cinema: "film"
        case .archive: "rectangle.grid.3x2"
        }
    }
    var summary: String {
        switch self {
        case .classic: "Your current gallery."
        case .prism: "An open glass gallery. Large covers, light and space."
        case .cinema: "A private viewing room. Dark surfaces and wide album posters."
        case .archive: "A photographer’s contact sheet. A clear index for a large library."
        }
    }
    var accent: Color {
        switch self {
        case .classic, .prism: Color(red: 0.04, green: 0.42, blue: 0.40)
        case .cinema: Color(red: 0.96, green: 0.75, blue: 0.39)
        case .archive: Color(red: 0.10, green: 0.26, blue: 0.57)
        }
    }
    var colorScheme: ColorScheme { self == .cinema ? .dark : .light }
}

struct GalleryDesignPreviewPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose a Design").font(.largeTitle.weight(.semibold))
                    Text("Three directions, the same photos and spatial viewers.")
                        .font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.accessibilityIdentifier("gallery-design-done")
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 20)], spacing: 20) {
                    ForEach(GalleryDesignDirection.allCases) { direction in
                        Button {
                            selection = direction.rawValue
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Image(systemName: direction.symbol).font(.title)
                                    Spacer()
                                    if selection == direction.rawValue {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                                Text(direction.title).font(.title2.weight(.semibold))
                                Text(direction.summary).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .foregroundStyle(direction == .cinema ? Color.white : Color(red: 0.10, green: 0.13, blue: 0.17))
                            .padding(24).frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                            .background(direction == .cinema ? Color(red: 0.10, green: 0.12, blue: 0.17) : Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
                            .overlay {
                                RoundedRectangle(cornerRadius: 24).stroke(direction.accent.opacity(selection == direction.rawValue ? 1 : 0.3), lineWidth: selection == direction.rawValue ? 3 : 1)
                            }
                        }
                        .buttonStyle(.plain).hoverEffect(.highlight)
                        .accessibilityLabel("\(direction.title). \(direction.summary)")
                        .accessibilityAddTraits(selection == direction.rawValue ? .isSelected : [])
                        .accessibilityIdentifier("gallery-design-\(direction.rawValue)")
                    }
                }
            }
        }
        .padding(32).frame(minWidth: 680, idealWidth: 920, maxWidth: 1120, minHeight: 560)
        .background(.regularMaterial)
    }
}
