import AppKit

/// --selftest [seconds]: scripted run, prints one JSON object as the last stdout line.
///
/// Timeline (seconds after the panel is shown):
///   0.6 peek, 1.2 expanded, 2.0 idle          (programmatic, hover disabled)
///   2.6 hover enabled, cursor warped into notch centre
///       -> expect poll hover enter -> peek, then expanded after 0.25 s
///   3.8 cursor restored -> expect hover exit -> idle
///   max(seconds, 4.6) print JSON, exit 0
extension SpikeController {
    func runSelfTest(seconds: Double) {
        let end = max(seconds, 4.6)
        if end != seconds { log("selftest", "requested \(seconds)s is shorter than the script; using \(end)s") }
        log("selftest", "start duration=\(end)s")
        hoverEnabled = false

        after(0.6) { self.setState(.peek, reason: "selftest") }
        after(1.2) { self.setState(.expanded, reason: "selftest") }
        after(2.0) { self.setState(.idle, reason: "selftest") }

        var saved = CGPoint.zero
        after(2.6) {
            saved = NSEvent.mouseLocation
            self.hoverEnabled = true
            self.hovering = false
            let target = CGPoint(x: self.model.geometry.anchorRect.midX, y: self.model.geometry.anchorRect.midY)
            self.warpActive = true
            let err = CGWarpMouseCursorPosition(Self.toCG(target))
            // Re-associate so the next real mouse move is not ignored.
            CGAssociateMouseAndMouseCursorPosition(1)
            log("selftest warp", "from=\(fmt(saved)) to=\(fmt(target)) cgError=\(err.rawValue) mouseLocationNow=\(fmt(NSEvent.mouseLocation))")
        }
        after(3.8) {
            let err = CGWarpMouseCursorPosition(Self.toCG(saved))
            CGAssociateMouseAndMouseCursorPosition(1)
            log("selftest restore cursor", "to=\(fmt(saved)) cgError=\(err.rawValue) hoverFiredFromWarp=\(self.hoverFiredFromWarp) swiftUIHoverFiredFromWarp=\(self.swiftUIHoverFiredFromWarp)")
            self.warpActive = false
        }
        after(end) { self.finishSelfTest() }
    }

    /// AppKit global coords (origin bottom-left of primary display) -> Quartz global
    /// coords (origin top-left of primary display).
    static func toCG(_ p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    func finishSelfTest() {
        let frontmostAfter = describeApp(NSWorkspace.shared.frontmostApplication)
        log("selftest", "done frontmostBefore=\(frontmostBefore) frontmostAfter=\(frontmostAfter)")
        let g = model.geometry
        let result: [String: Any] = [
            "notchRect": rectDict(g.anchorRect),
            "mode": g.isNotchMode ? "notch" : "pill",
            "screenHasNotch": g.screenHasNotch,
            "panelFrame": rectDict(panel.frame),
            "windowLevel": ["name": options.levelName, "rawValue": level.rawValue],
            "frontmostBefore": frontmostBefore,
            "frontmostAfter": frontmostAfter,
            "appBecameActive": appBecameActive,
            "panelBecameKey": panelBecameKey,
            "panelVisible": panel.isVisible && panel.occlusionState.contains(.visible),
            "hoverFiredFromWarp": hoverFiredFromWarp,
            "swiftUIHoverFiredFromWarp": swiftUIHoverFiredFromWarp,
            "statesVisited": statesVisited,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        } else {
            print("{\"error\":\"json serialization failed\"}")
        }
        fflush(stdout)
        exit(0)
    }
}
