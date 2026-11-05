<!-- Target audience: app developers -->
# Lightkeeper: host-target SwiftUI theme

A drop-in extraction of the selected Simple Vision Gallery07b visual system. It provides warm/cool lit surface roles, native glass with a restrained dark tint, buttons, search, rows, cards, action labels and a two-row dock. App state, actions, accent choice and persistence belong to the host.

This is a **static approximation** of a warm key, cool fill, edge bevel and occlusion on a backing plane. It is not physical light, scene-aware relighting, volumetric fog or a photo filter. Text and media do not pass through the shader.

The design run stopped at its06:00 WAT deadline on5 November2026 with **zero qualifying wins**.07b had the highest complete-pitch mean, but it did not pass the all-judge/two-round rule. See [RUBRIC.md](RUBRIC.md) for the exact scores and limits. The extracted sample itself has not received those council scores.

## Copy into an app

1. Copy `Lightkeeper.swift`, `LightkeeperSample.swift` and `Lightkeeper.metal` into your Xcode app project. The sample file is optional for your shipping UI.
2. Add both Swift files and the Metal file to the SAME application target. In Build Phases, the Metal file must be compiled as source; copying it as a plain resource is insufficient.
3. Build on a target supporting SwiftUI shaders and the used controls. The verified target is visionOS26.1 Simulator, built with the installed visionOS27.0 SDK. Other OS targets have not been compiled or visually verified. The non-visionOS material branch is a fallback, not an all-platform support claim.
4. Put the sample in a window to check shader lookup and materials:

```swift
import SwiftUI

struct ThemePreview: View {
    var body: some View {
        LightkeeperSample()
            .lightkeeperTheme()
            .frame(width: 1080, height: 900)
    }
}
```

`ShaderFunction(library: .default, name: "lightkeeperSurfaceLight")` resolves the HOST APP target's default Metal library. This folder is deliberately not a Swift package or framework. Moving it into a separate resource bundle requires changing shader-library lookup and testing that package; that has not been done here. No separate framework stack, package download or asset catalog is required.

## Use the primitives

```swift
struct ExampleEditor: View {
    @State private var query = ""
    @State private var opened = false

    var body: some View {
        LightkeeperCard {
            VStack(alignment: .leading, spacing: 20) {
                LightkeeperSearchField(query: $query, placeholder: "Find a note")
                LightkeeperRow("Field notes", detail: "An example row", symbol: "doc.text") {
                    Button("Open") { opened = true }
                        .buttonStyle(LightkeeperPrimaryButtonStyle())
                }
            }
        }
        .lightkeeperTheme(LightkeeperTokens())
        .preferredColorScheme(.dark)
    }
}
```

Use `.lightkeeperSurface(.canvas/.raised/.control)` for backing planes. Use `.lightkeeperBackdrop()` on floating controls or a panel that needs native material. On visionOS it uses native `glassBackgroundEffect` plus the graded0.55 lit dark tint. A view modifier does not present a menu/sheet or make content private; those remain host behavior. Keep real menus local to their popover instead of blurring an entire app to imitate them.

`LightkeeperDock` accepts two view-builder rows and a width. Its first row has32pt horizontal gaps; `LightkeeperActionLabel` supplies a visible caption and44pt minimum height. Its geometry is chrome only: native image depth, forward-projection clearance, camera placement, media identity, playback and privacy covers are NOT included. Supply actions with Buttons and maintain those contracts in your app.

Inject a matching accent and foreground pair:

```swift
.lightkeeperTheme(LightkeeperTokens(accent: .orange, onAccent: .black))
```

Default accent is sRGB`#FFC569` with black text. Arbitrary injected colors are not automatically contrast-corrected. The host must check its chosen pair on the actual surfaces and states. Tokens are values; the theme reads or writes no UserDefaults, files, Photos, app managers or accounts.

## Effects and accessibility

System Reduce Transparency OR the preview override replaces lit planes/materials with opaque role fills. System Reduce Motion OR the preview override suppresses the custom press-scale animations. Native controls and hover feedback remain platform-managed; still screenshots do not prove motion comfort or every OS animation.

```swift
LightkeeperSample(state: .reducedTransparency).lightkeeperTheme()
LightkeeperSample(state: .reducedMotion).lightkeeperTheme()
LightkeeperSample(state: .disabled).lightkeeperTheme()
LightkeeperSample(state: .search).lightkeeperTheme()
```

`LightkeeperSampleState` is a sample/capture preset, not an app model. Search has a real binding, neutral clear action and an optional spinner. Sample buttons, toggle and slider own simple example state. Recreate the sample identity if switching its initial search preset while it is already alive. Disabled custom buttons retain readable labels and native disabled controls remain visibly unavailable; hosts should explain why their own action is disabled.

Surface decoration is hidden from accessibility. Text, labels and native input controls keep their normal SwiftUI semantics; action labels have an explicit accessible title. The isolated1080×900 harness also rendered accessibility1 type and a long Card/Row/Search/Button stack. The action caption keeps its intrinsic width to avoid the observed Previous truncation at that type size. These two fixtures are not proof of every type/width combination: the host must give action rows sufficient space or adapt its layout. VoiceOver, other large type/width combinations, keyboard focus, hover/press interaction and headset comfort still need testing in the integrating app.

## Verification and dependencies

The standalone harness under the locally ignored `.codex-tests/lightkeeper-harness/` compiles only these exported files plus its tiny App entry. It imports no Gallery models, Photos, GalleryAppearance or persistence layer. It uses an isolated simulator app bundle and the same owned Simulator; it does not install into or change the Gallery app.

The rendered sample states are normal, reduced transparency, reduced motion, disabled and search. Raw captures/build logs and export/app hash proofs are under `workspaces/design-overhaul/lightkeeper-export-03/`. These are render evidence, not council wins, real user testing, a performance measurement or a hardware pass. The parent owns the final six-reviewer pixel pass and release coordination. The Gallery07b source/visual binding remains separate and unchanged.

Runtime source dependencies are SwiftUI, its shader bridge, Metal's standard library, system fonts and SF Symbols. The isolated build helper uses XcodeGen/Xcode/simctl as development tools; shipped theme code does not depend on those tools. No external images or Apple Photos reference pictures are included.

Credits: extracted from this repository's selected07b surface/material/control code and its original static Metal shader. SwiftUI, Metal, native glass, SF Symbols and Simulator belong to Apple's SDK/platform. The sample text and simple UI composition are original example content. Comparison references remain evidence outside this folder; they are not licensed/vendored theme assets. This extraction does not add a new standalone license grant; follow the host repository's terms and Apple's SDK/SF Symbols terms.
