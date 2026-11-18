import AppKit

struct Options {
    /// nil = normal mode. Otherwise run the scripted self-test for this many seconds.
    var selftestSeconds: Double?
    var quitAfter: Double?
    var forcePill = false
    /// Window level name, see `resolveLevel`. Lets the orchestrator compare levels
    /// without recompiling.
    var levelName = "statusBar"

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--selftest":
                o.selftestSeconds = 6
                if i + 1 < args.count, let v = Double(args[i + 1]) {
                    o.selftestSeconds = v
                    i += 1
                }
            case "--quit-after":
                if i + 1 < args.count, let v = Double(args[i + 1]) {
                    o.quitAfter = v
                    i += 1
                } else {
                    log("args", "--quit-after needs a number of seconds; ignored")
                }
            case "--force-pill":
                o.forcePill = true
            case "--level":
                if i + 1 < args.count {
                    o.levelName = args[i + 1]
                    i += 1
                }
            case "-h", "--help":
                print("""
                usage: NotchSpike [--selftest [seconds]] [--quit-after <seconds>] [--force-pill]
                                  [--level mainMenu|statusBar|popUpMenu|screenSaver|shielding]
                """)
                exit(0)
            default:
                log("args", "unknown argument \(a); ignored")
            }
            i += 1
        }
        return o
    }
}

/// Window level candidates, lowest to highest.
/// The menu bar itself draws at NSMainMenuWindowLevel (24). The notch area is part of
/// the menu bar strip, so anything strictly above 24 should draw over it.
/// - mainMenu (24): same level as the menu bar; expected to be ordered ambiguously against it.
/// - statusBar (25): first level above the menu bar. Default here.
/// - popUpMenu (101): above status items and open menus.
/// - screenSaver (1000): what DynamicNotchKit uses.
/// - shielding: CGShieldingWindowLevel(), above almost everything, incl. some system UI.
/// Which one is actually needed to draw over the notch is NOT VERIFIED until the
/// orchestrator runs the spike with each value and looks at the screen.
func resolveLevel(_ name: String) -> NSWindow.Level {
    switch name {
    case "mainMenu": return .mainMenu
    case "statusBar": return .statusBar
    case "popUpMenu": return .popUpMenu
    case "screenSaver": return .screenSaver
    case "shielding": return NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    default:
        log("args", "unknown level \(name); using statusBar")
        return .statusBar
    }
}
