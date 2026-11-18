import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    @Published var state: NotchState = .idle
    @Published var geometry: NotchGeometry
    /// SwiftUI .onHover on the shape, logged separately from the polling hover so we
    /// can see whether tracking-area hover fires at all (e.g. after a cursor warp).
    var onSwiftUIHover: ((Bool) -> Void)?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let g = model.geometry
        let s = g.size(for: model.state)
        let r = g.radii(for: model.state)

        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: r.top,
                                   bottomLeadingRadius: r.bottom,
                                   bottomTrailingRadius: r.bottom,
                                   topTrailingRadius: r.top,
                                   style: .continuous)
                .fill(Color.black)
                .frame(width: s.width, height: s.height)
                .overlay(alignment: .bottom) {
                    if model.state == .expanded {
                        Text("NotchSpike: expanded")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.bottom, 16)
                            .transition(.opacity)
                    }
                }
                .shadow(color: .black.opacity(model.state == .idle ? 0 : 0.35), radius: 8, y: 2)
                .onHover { model.onSwiftUIHover?($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A window at the top of a notched screen can get a top safe-area inset;
        // ignore it so the shape is flush with the screen edge.
        .ignoresSafeArea()
    }
}
