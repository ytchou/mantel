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
    /// Width beside the camera the header icon needs.
    private static let headerIconRoom: CGFloat = 40

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
        let ear = geometry.earRadius(level: wing == nil ? state.level : nil)

        shape
            .fill(Color.black)
            .background(NotchEars(radius: ear).fill(Color.black))
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
                // Expanded: the owner's icon in the header row, beside the
                // camera, where there is room for it.
                if state.level == .expanded, wing == nil, geometry.isNotch,
                   (rect.width - geometry.anchorRect.width) / 2 >= Self.headerIconRoom,
                   let symbol = runtime.blocks.first(where: { $0.id == state.owner })?.info.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .opacity(0.8)
                        .frame(height: geometry.headerHeight)
                        .padding(.leading, NotchStyle.padding)
                        .transition(.opacity)
                        .accessibilityHidden(true)
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

/// Two concave curves outside the shape's top corners, from the screen edge
/// down into the shape's sides, so the shape grows out of the bezel instead
/// of standing on it. Drawn behind the shape; they take no clicks.
struct NotchEars: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard radius > 0 else { return path }
        let r = min(radius, rect.height / 2)
        // Left: from the screen edge beside the corner, curving into the side.
        path.move(to: CGPoint(x: rect.minX - r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX - r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        // Right, mirrored.
        path.move(to: CGPoint(x: rect.maxX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + r, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
