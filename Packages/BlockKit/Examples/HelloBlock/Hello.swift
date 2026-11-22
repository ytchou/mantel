import BlockKit

/// The kit's example. On hover it shows a peek laid out like the
/// now-playing block: an artwork placeholder, two lines of text, a speaker
/// symbol and a volume bar.
@main
struct Hello: Block {
    /// Same size and time as the now-playing peek.
    static let peekWidth = 380.0
    static let peekHeight = 52.0
    static let seconds = 3.0

    func start(_ ctx: Context) {
        var hovers = 0
        ctx.on(.pointerHover) { event in
            // A replayed event is old news: nothing to show.
            guard event.pointerHover?.isInside == true, !event.replay else { return }
            hovers += 1
            ctx.present(
                peek: ViewSlot(width: Self.peekWidth, height: Self.peekHeight, root: Self.peek(hovers: hovers)),
                for: Self.seconds,
                dismissIfNotShown: true
            )
        }
    }

    /// Values from `NotchStyle` and the now-playing block's `PeekTree`
    /// (`blocks/nowplaying` in the topnotch-blocks repository). The row
    /// spacing is left to the app's default.
    static func peek(hovers: Int) -> ViewNode {
        let volume = 0.5
        return .hstack(padding: .init(horizontal: 18), [
            .box(width: 36, height: 36, cornerRadius: 8, fillOpacity: 0.12, .symbol("music.note", size: 15, opacity: 0.8)),
            .vstack(spacing: 2, alignment: .start, [
                .text("Hello from a block", style: .title),
                .text(hovers == 1 ? "Hovered once" : "Hovered \(hovers) times", style: .secondary),
            ]),
            .spacer(minLength: 4),
            .symbol("speaker.wave.2.fill", size: 12, opacity: 0.8, width: 18),
            .progress(volume, width: 64).accessibilityLabel("Volume \(Int((volume * 100).rounded())) percent"),
        ])
    }
}
