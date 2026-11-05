// Target audience: app developers. Self-contained examples; no external pictures or app services.
import SwiftUI

public enum LightkeeperSampleState: String, CaseIterable, Sendable {
    case normal, reducedTransparency = "reduced-transparency", reducedMotion = "reduced-motion"
    case disabled, search
}

public struct LightkeeperSample: View {
    private let state: LightkeeperSampleState
    @State private var query: String
    @State private var keepCopy = true
    @State private var amount = 0.6
    @State private var lastAction = "Ready"
    @Environment(\.lightkeeperTokens) private var tokens

    public init(state: LightkeeperSampleState = .normal) {
        self.state = state
        _query = State(initialValue: state == .search ? "notes" : "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lightkeeper").font(.system(size: 32, weight: .semibold))
                    Text("Surfaces and controls · example content")
                        .foregroundStyle(tokens.secondaryForeground)
                }
                Spacer()
                Image(systemName: "square.stack.3d.up").font(.system(size: 38, weight: .light))
                    .foregroundStyle(tokens.accent)
            }
            LightkeeperSearchField(query: $query, placeholder: "Search examples", isSearching: state == .search)
            HStack(alignment: .top, spacing: 24) {
                LightkeeperCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Example workspace").font(.title2.weight(.semibold))
                        LightkeeperRow("Field notes", detail: "A card with a supporting line", symbol: "doc.text") {
                            Image(systemName: "chevron.right").foregroundStyle(tokens.secondaryForeground)
                        }
                        Divider()
                        Toggle("Keep a local copy", isOn: $keepCopy)
                        Slider(value: $amount) { Text("Preview size") }
                        HStack(spacing: 12) {
                            Button("Cancel") { lastAction = "Cancelled" }.buttonStyle(LightkeeperSecondaryButtonStyle())
                            Button("Open item") { lastAction = "Opened" }.buttonStyle(LightkeeperPrimaryButtonStyle())
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Actions").font(.headline)
                        LightkeeperRow("Rename", symbol: "pencil") { EmptyView() }
                        Divider()
                        LightkeeperRow("Move", symbol: "folder") { EmptyView() }
                    }
                    .padding(24).frame(width: 330).lightkeeperBackdrop(cornerRadius: 24)
                    LightkeeperDock(width: 330) {
                        Button { lastAction = "Previous" } label: { LightkeeperActionLabel("Previous", symbol: "chevron.left") }
                        Button { lastAction = "Saved" } label: { LightkeeperActionLabel("Save", symbol: "bookmark") }
                        Button { lastAction = "Next" } label: { LightkeeperActionLabel("Next", symbol: "chevron.right") }
                    } secondary: {
                        HStack { Text("Example item").font(.callout); Spacer(); Image(systemName: "ellipsis") }
                    }
                }
            }
            Text(state == .disabled ? "Controls are disabled in this example." : lastAction)
                .font(.callout).foregroundStyle(tokens.secondaryForeground)
            Spacer(minLength: 0)
        }
        .padding(40)
        .disabled(state == .disabled)
        .background { LightkeeperSurface(role: .canvas, cornerRadius: 28) }
        .lightkeeperReduceEffects(transparency: state == .reducedTransparency, motion: state == .reducedMotion)
        .preferredColorScheme(.dark)
    }
}
