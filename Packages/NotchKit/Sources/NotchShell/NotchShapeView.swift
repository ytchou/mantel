import AppKit
import NotchCore
import Observation
import SwiftUI

/// The geometry the view draws with. Replaced when the screen changes.
@MainActor
@Observable
final class ShellLayout {
    var geometry: NotchGeometry
    init(geometry: NotchGeometry) { self.geometry = geometry }
}

/// Hosting view that acts on the first click: the panel never becomes key, so
/// without this the first click would only try to activate the window.
final class NotchHostingView: NSHostingView<NotchShapeView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Draws `runtime.state`: the black shape, and the block's content below the notch.
struct NotchShapeView: View {
    let runtime: NotchRuntime
    let layout: ShellLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ContentKey: Hashable {
        let id: UUID
        let level: NotchLevel
    }

    var body: some View {
        let geometry = layout.geometry
        let state = runtime.state
        let rect = geometry.localRect(geometry.shapeRect(for: state))
        let radii = geometry.radii(level: state.level)
        let shape = UnevenRoundedRectangle(topLeadingRadius: radii.top,
                                           bottomLeadingRadius: radii.bottom,
                                           bottomTrailingRadius: radii.bottom,
                                           topTrailingRadius: radii.top,
                                           style: .continuous)

        shape
            .fill(Color.black)
            .overlay(alignment: .top) {
                if let content = NotchGeometry.content(for: state),
                   let presentation = state.presentation, let level = state.level {
                    content.makeView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Never lay content out under the hardware notch.
                        .padding(.top, geometry.headerHeight)
                        .id(ContentKey(id: presentation.id, level: level))
                        .transition(.opacity)
                        .clipShape(shape)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(shape)
            // Controls inside the content take their own clicks first.
            .onTapGesture { runtime.send(.click) }
            .shadow(color: .black.opacity(state.level == nil ? 0 : 0.35), radius: 8, y: 2)
            .padding(.leading, rect.minX)
            .padding(.top, rect.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: rect)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            // The window sits at the top of a notched screen; ignore its safe area
            // so the shape is flush with the screen edge.
            .ignoresSafeArea()
    }
}
