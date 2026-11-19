import SwiftUI

/// The look every block's notch views share: white on black, one title size,
/// one secondary size, the same padding and the same capsule buttons. The
/// shell supplies the black shape and the dark colour scheme.
///
/// Optional: a block can draw anything, but views built from these read as
/// one app.
public enum NotchStyle {
    /// Space between the shape's edge and the content, left and right.
    public static let padding: CGFloat = 18
    /// Space between items in a row, and between lines in a stack.
    public static let spacing: CGFloat = 10

    /// The main line: a track, a file name, a heading.
    public static let title = Font.system(size: 15, weight: .semibold)
    /// Text in rows and buttons.
    public static let body = Font.system(size: 12, weight: .medium)
    /// The second line under a title: an artist, a state, a count.
    public static let secondary = Font.system(size: 11)
    public static let secondaryOpacity = 0.5

    /// Side of the image at the start of a peek: artwork, a thumbnail, an icon.
    public static let leadingImageSize: CGFloat = 36
    public static let leadingImageRadius: CGFloat = 8
}

/// A capsule button on black: white at 12% behind the label, brighter while
/// pressed. Pass a tint for the label of the main action.
public struct NotchCapsuleButtonStyle: ButtonStyle {
    public var tint: Color

    public init(tint: Color = .white) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NotchStyle.body)
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.12)))
            .contentShape(Capsule())
    }
}

public extension ButtonStyle where Self == NotchCapsuleButtonStyle {
    /// See `NotchCapsuleButtonStyle`.
    static var notchCapsule: NotchCapsuleButtonStyle { NotchCapsuleButtonStyle() }
    static func notchCapsule(tint: Color) -> NotchCapsuleButtonStyle { NotchCapsuleButtonStyle(tint: tint) }
}
