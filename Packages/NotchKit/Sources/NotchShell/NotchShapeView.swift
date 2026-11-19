import AppKit
import NotchCore
import Observation
import SwiftUI

/// The geometry the view draws with. Replaced when the screen changes.
@MainActor
@Observable
final class ShellLayout {
    var geometry: NotchGeometry
    /// True while the pointer is over the shape. Set by the controller.
    var isHovering = false
    init(geometry: NotchGeometry) { self.geometry = geometry }
}

/// Hosting view that acts on the first click: the panel never becomes key, so
/// without this the first click would only try to activate the window.
final class NotchHostingView: NSHostingView<NotchShapeView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Builds the menu for a right-click on the notch. Nil shows no menu.
    var menuProvider: (@MainActor () -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Draws `runtime.state`: the black shape, and the block's content below the
/// notch. When a block shows something, the whole notch grows into one
/// rounded rectangle from the top edge of the screen.
struct NotchShapeView: View {
    let runtime: NotchRuntime
    let layout: ShellLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the idle shape grows downward while the pointer is on it.
    private static let idleHoverGrowth: CGFloat = 8

    private struct ContentKey: Hashable {
        let id: UUID
        let level: NotchLevel
    }

    var body: some View {
        let geometry = layout.geometry
        let state = runtime.state
        let base = geometry.localRect(geometry.shapeRect(for: state))
        // With nothing to show, the notch still grows a little under the
        // pointer, so the user can see the app is running.
        let growth = state.level == nil && layout.isHovering ? Self.idleHoverGrowth : 0
        let rect = CGRect(x: base.minX, y: base.minY, width: base.width, height: base.height + growth)
        let radii = geometry.radii(level: NotchGeometry.wing(for: state) == nil ? state.level : nil)
        let wing = NotchGeometry.wing(for: state)
        let shape = UnevenRoundedRectangle(topLeadingRadius: radii.top, bottomLeadingRadius: radii.bottom,
                                           bottomTrailingRadius: radii.bottom, topTrailingRadius: radii.top,
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
            .overlay(alignment: .topLeading) {
                if let wing, let presentation = state.presentation {
                    // Beside the notch on a notched screen; inside the pill otherwise.
                    wing.makeView()
                        .frame(width: geometry.isNotch ? rect.width - geometry.anchorRect.width : rect.width,
                               height: geometry.headerHeight)
                        .id(ContentKey(id: presentation.id, level: .peek))
                        .transition(.opacity)
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
