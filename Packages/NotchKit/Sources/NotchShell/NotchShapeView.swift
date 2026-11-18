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
        let shape = NotchOutline(neckWidth: geometry.neck?.width, neckHeight: geometry.headerHeight,
                                 topRadius: radii.top, bottomRadius: radii.bottom)

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

/// The black shape. On a notched screen it is only as wide as the notch while
/// level with it, and widens below the menu bar, so it never covers menu bar
/// items. Without a neck (a pill, or a shape no wider than the notch) it is a
/// rounded rectangle.
struct NotchOutline: Shape {
    var neckWidth: CGFloat?
    var neckHeight: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    /// Radius of the body's top corners, where it widens under the menu bar.
    private static let shoulderRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        guard let neckWidth, neckWidth < rect.width - 1, neckHeight < rect.height else {
            return UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
                                          bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
                                          style: .continuous).path(in: rect)
        }
        var path = Path(CGRect(x: rect.midX - neckWidth / 2, y: rect.minY, width: neckWidth, height: neckHeight + 1))
        let body = CGRect(x: rect.minX, y: rect.minY + neckHeight, width: rect.width, height: rect.height - neckHeight)
        let shoulder = min(Self.shoulderRadius, body.height / 2)
        path.addPath(UnevenRoundedRectangle(topLeadingRadius: shoulder, bottomLeadingRadius: min(bottomRadius, body.height / 2),
                                            bottomTrailingRadius: min(bottomRadius, body.height / 2), topTrailingRadius: shoulder,
                                            style: .continuous).path(in: body))
        return path
    }
}
