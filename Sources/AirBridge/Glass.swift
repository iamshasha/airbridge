import SwiftUI

// Liquid Glass on macOS 26 and later; materials and the classic button styles before that.

extension View {
    /// A glass surface in `shape`. `tint` colours the glass; `interactive` makes it respond to the pointer.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(tint.map { AnyShapeStyle($0.opacity(0.15)) } ?? AnyShapeStyle(.quaternary.opacity(0.5)), in: shape)
        }
    }

    /// Small tinted capsule label ("Trusted", "SYNC").
    func glassBadge(_ tint: Color) -> some View {
        padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .glassSurface(in: Capsule(), tint: tint.opacity(0.25))
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Groups nearby glass shapes so they blend and morph together (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
