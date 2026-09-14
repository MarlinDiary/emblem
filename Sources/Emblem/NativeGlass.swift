import SwiftUI

// System materials belong to the control layer, not photos, forms or source cards.
enum NativeAppearance {
    static func usesGlass(majorVersion: Int, reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        majorVersion >= 26 && !reduceTransparency && !increasedContrast
    }
}
private struct PortraitActionStyle: ViewModifier {
    var prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), NativeAppearance.usesGlass(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}
extension View {
    func portraitAction(prominent: Bool = false) -> some View { modifier(PortraitActionStyle(prominent:prominent)) }
    /// Let macOS progressively soften content beneath the titlebar/controls.
    /// This changes the scroll edge, never the photos or their hit-test area.
    func portraitScrollTop() -> some View { modifier(PortraitScrollTopStyle()) }
}

private struct PortraitScrollTopStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(
                NativeAppearance.usesGlass(
                    majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: contrast == .increased
                ) ? .soft : .hard,
                for: .top
            )
        } else {
            content
        }
    }
}
struct NativeActionGroup<Content:View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing:12) { content() } }
        else { content() }
    }
}
