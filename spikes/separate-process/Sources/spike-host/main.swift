import AppKit
import SpikeShared

// spike-host <mode> [options]
//   rtt     [--n 2000] [--launches 10]
//   view    --option inproc|described|window|layer [--route reparent|window] [--n 200]
//   crash   --option described|window|layer --how kill|fatal [--route ...]
//   hang    --option described|window|layer [--route ...]
//   manual  --option inproc|described|window|layer [--route ...] [--seconds 60]

let args = CommandLine.arguments
func arg(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: "--" + name), i + 1 < args.count { return args[i + 1] }
    return def
}
let mode = args.count > 1 ? args[1] : "view"
let option = arg("option", "inproc")
let route = arg("route", "reparent")
let n = Int(arg("n", "200"))!

// Safety net: never leave a window near the notch for long.
let watchdog = Double(arg("seconds", "60"))! + 90
DispatchQueue.main.asyncAfter(deadline: .now() + watchdog) { log("watchdog: exiting"); exit(2) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated(f) }
}

@MainActor func finish(_ host: Host?, code: Int32 = 0) {
    host?.quitBlock()
    after(0.3) {
        if let pid = host?.block?.pid, kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        exit(code)
    }
}

@MainActor func contentRectTopLeft(_ host: Host) -> CGRect {
    let r = host.layout.contentRectInPanel(expanded: host.hostModel.expanded)
    return CGRect(x: r.minX, y: NotchLayout.panelSize.height - r.maxY, width: r.width, height: r.height)
}

@MainActor func printWindows(_ host: Host, _ label: String) {
    let ws = onScreenWindows()
    let h = ws.first { $0.number == host.panel.windowNumber }
    let b = host.blockWindowNumber.flatMap { num in ws.first { $0.number == num } }
    func d(_ w: WinInfo?) -> String {
        guard let w else { return "not on screen" }
        return "index=\(w.index) layer=\(w.layer) alpha=\(w.alpha) bounds=\(w.bounds)"
    }
    print("RESULT \(label) windows: host panel \(d(h)); block window \(d(b))")
    if let h, let b { print("RESULT \(label) block window in front of host panel: \(b.index < h.index)") }
}

@MainActor func printStats(_ host: Host, _ results: [Kind: [Sample]]) {
    let o = host.option == "layer" ? "layer(\(host.route))" : host.option
    for kind in Kind.allCases {
        guard let ss = results[kind] else { continue }
        let timeouts = ss.filter { !$0.tCommit.isFinite }.count
        let badOrder = ss.filter { $0.tBody > $0.tCommit }.count
        print("RESULT \(o) \(kind.rawValue) commit    \(Stats(ss.map { $0.commit }).line) timeouts=\(timeouts) bodyAfterCommit=\(badOrder)")
        print("RESULT \(o) \(kind.rawValue) frame-est \(Stats(ss.map { $0.frame }).line)")
        if host.option == "described" && kind != .resize {
            print("RESULT \(o) \(kind.rawValue) reply-arrived \(Stats(ss.map { $0.tReply - $0.t0 }).line)")
        }
        if host.option == "window" || host.option == "layer" {
            print("RESULT \(o) \(kind.rawValue) block-received \(Stats(ss.map { $0.tRecv - $0.t0 }).line)")
            if kind == .resize {
                print("RESULT \(o) resize block-commit-minus-host-commit \(Stats(ss.map { $0.tCommit - $0.tHostCommit }).line)")
            }
        }
    }
    print("RESULT commitHandlerFailures=\(Probe.commitHandlerFailures) displayLinkTicks=\(FrameClock.ticks)")
}

/// Show panel and (unless inproc) start + set up the block. `ready` runs when
/// the block's view is in place.
@MainActor func bringUp(_ host: Host, _ ready: @escaping () -> Void) {
    host.showPanel()
    if host.option == "inproc" { after(0.3, ready); return }
    let tSpawn = now()
    host.startBlock {
        host.onReady = {
            print(String(format: "RESULT %@ spawn-to-view-ready %.1f ms", host.option, (now() - tSpawn) * 1000))
            after(0.4, ready)
        }
        host.setupBlock()
        if host.option == "described" { let r = host.onReady; host.onReady = nil; r?() }
    }
}

// MARK: - modes

@MainActor func runView() {
    let host = Host(option: option, route: route, manual: false)
    bringUp(host) {
        if host.option == "window" {
            printWindows(host, "window")
            if let b = host.blockWindowNumber { print("RESULT block-window " + captureWindow(b, name: "window-blockwindow", brightIn: CGRect(x: 0, y: 0, width: 400, height: 100))) }
        }
        print("RESULT before " + captureWindow(host.panel.windowNumber, also: host.blockWindowNumber, name: "\(option)-\(route)-before", brightIn: contentRectTopLeft(host)))
        runSeries(host, kinds: Kind.allCases, n: n) { results in
            printStats(host, results)
            print("RESULT after " + captureWindow(host.panel.windowNumber, also: host.blockWindowNumber, name: "\(option)-\(route)-after", brightIn: contentRectTopLeft(host)))
            print("RESULT screen-capture preflight (no prompt): \(CGPreflightScreenCaptureAccess())")
            FrameClock.uninstall(); host.block?.channel.send(.idle)
            measureIdle(pid: getpid(), label: "host(\(option))") {
                guard let pid = host.block?.pid else { finish(host); return }
                measureIdle(pid: pid, label: "block(\(option))") { finish(host) }
            }
        }
    }
}

@MainActor func runCrash() {
    let how = arg("how", "kill")
    let host = Host(option: option, route: route, manual: false)
    bringUp(host) {
        runSeries(host, kinds: [.hover, .click], n: 5) { _ in
            print("RESULT shown " + captureWindow(host.panel.windowNumber, also: host.blockWindowNumber, name: "crash-\(option)-\(how)-shown", brightIn: contentRectTopLeft(host)))
            if option == "window" { printWindows(host, "crash-shown") }
            var tK = 0.0
            host.onBlockClosed = { t in
                print(String(format: "RESULT crash %@ %@: socket EOF after %.2f ms", option, how, (t - tK) * 1000))
                if option == "described" { host.hostModel.showNodes = false; host.hostModel.placeholder = "Block stopped" }
            }
            host.onBlockExit = { t, status in
                let sig = (status & 0x7f)
                print(String(format: "RESULT crash %@ %@: process exit seen after %.2f ms (signal %d)", option, how, (t - tK) * 1000, sig))
            }
            let pid = host.block!.pid
            tK = now()
            if how == "kill" { kill(pid, SIGKILL) } else { host.block!.channel.send(.crash) }
            after(2.0) {
                print("RESULT crash \(option) \(how): host still running (pid \(getpid()))")
                if option == "window" { printWindows(host, "crash-after") }
                print("RESULT after-crash " + captureWindow(host.panel.windowNumber, also: host.blockWindowNumber, name: "crash-\(option)-\(how)-after", brightIn: contentRectTopLeft(host)))
                // Host still responsive: a host-only resize, measured.
                host.perform(.resize) { _ in }
                // Restart the block.
                host.onBlockClosed = nil; host.onBlockExit = nil
                host.layerHostView?.removeFromSuperview(); host.layerHostView = nil
                host.hostModel.placeholder = nil
                host.hostModel.showNodes = option == "described"
                let tS = now()
                host.startBlock {
                    host.onReady = {
                        host.perform(.hover) { s in
                            print(String(format: "RESULT crash %@ %@: restart, spawn to first committed frame %.1f ms (commit ok: %@)",
                                         option, how, (s.tCommit - tS) * 1000, s.tCommit.isFinite ? "yes" : "no"))
                            after(0.2) {
                                print("RESULT restarted " + captureWindow(host.panel.windowNumber, also: host.blockWindowNumber, name: "crash-\(option)-\(how)-restarted", brightIn: contentRectTopLeft(host)))
                                finish(host)
                            }
                        }
                    }
                    host.setupBlock()
                    if option == "described" { let r = host.onReady; host.onReady = nil; r?() }
                }
            }
        }
    }
}

@MainActor func runHang() {
    let host = Host(option: option, route: route, manual: false)
    bringUp(host) {
        // Heartbeat: a ping answered on the block's MAIN thread every 50 ms.
        var sent: [Int: Double] = [:]
        var pingSeq = 0
        var tHang = 0.0, detected = false, recovered = false
        host.onPong = { s in
            sent.removeValue(forKey: s)
            if detected && !recovered && tHang > 0 {
                recovered = true
                print(String(format: "RESULT hang %@: heartbeat answered again %.0f ms after hang start", option, (now() - tHang) * 1000))
            }
        }
        let hb = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            pingSeq += 1; sent[pingSeq] = now()
            host.block?.channel.send(.ping(seq: pingSeq, onMain: true))
        }
        // Detector + host main-thread lateness, every 10 ms.
        var lastTick = now(), maxLateDuring = 0.0, maxLateBefore = 0.0
        let det = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let t = now()
            let late = t - lastTick - 0.01
            lastTick = t
            if tHang > 0 && t - tHang < 1.9 { maxLateDuring = max(maxLateDuring, late) } else if tHang == 0 { maxLateBefore = max(maxLateBefore, late) }
            if !detected, tHang > 0, let oldest = sent.values.min(), t - oldest > 0.25 {
                detected = true
                print(String(format: "RESULT hang %@: detected (oldest heartbeat unanswered > 250 ms) %.0f ms after hang start", option, (t - tHang) * 1000))
            }
        }
        RunLoop.main.add(hb, forMode: .common); RunLoop.main.add(det, forMode: .common)
        after(1.0) {
            tHang = now()
            host.block?.channel.send(.hang(seconds: 3))
            // Host input while the block hangs: 40 host-only shape resizes
            // (the block is not asked), in the first 1.8 s of the hang.
            var hostLat: [Double] = []
            var k = 0
            @MainActor func hostResize() {
                guard k < 40 else {
                    print("RESULT hang \(option): host-only resize during hang, host commit \(Stats(hostLat).line)")
                    return
                }
                k += 1
                host.seq += 1
                let s = host.seq, t0 = now()
                Probe.expect(version: s) { _, c, _ in hostLat.append(c - t0); after(0.03) { hostResize() } }
                host.hostModel.expanded.toggle()
                host.hostModel.version = s
            }
            after(0.1) { hostResize() }
            // Window list + capture at +2.0 s, outside the lateness window (capture blocks the main thread).
            after(2.0) {
                if option == "window" { printWindows(host, "hang-during") }
                print("RESULT during-hang " + captureWindow(host.panel.windowNumber, also: host.blockWindowNumber, name: "hang-\(option)-during", brightIn: contentRectTopLeft(host)))
            }
            after(5.0) {
                print(String(format: "RESULT hang %@: host main-thread max 10 ms-timer lateness: 1 s before hang=%.1f ms, first 1.9 s of hang=%.1f ms", option, maxLateBefore * 1000, maxLateDuring * 1000))
                hb.invalidate(); det.invalidate()
                finish(host)
            }
        }
    }
}

@MainActor func runManual() {
    let seconds = Double(arg("seconds", "60"))!
    let host = Host(option: option, route: route, manual: true)
    bringUp(host) {
        print("MANUAL: move the pointer onto the notch, click, drag a file over it. Ends in \(Int(seconds)) s.")
        host.panel.ignoresMouseEvents = true
        var inside = false
        // Pointer poll, as the real shell does (120 Hz).
        let poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
            let p = NSEvent.mouseLocation
            let shape = host.layout.toScreen(host.layout.shapeRectInPanel(expanded: host.hostModel.expanded))
            let now_ = shape.contains(p)
            host.panel.ignoresMouseEvents = !now_
            guard now_ != inside else { return }
            inside = now_
            let t = now()
            host.seq += 1
            let s = host.seq
            host.route(.hover(inside), seq: s, t0: t) { host.report("hover(manual)", $0) }
            if host.hostModel.expanded != inside { host.perform(.resize) { host.report("resize(manual)", $0) } }
        }
        RunLoop.main.add(poll, forMode: .common)
        after(seconds) { poll.invalidate(); finish(host) }
    }
}

func runRTT() {
    let launches = Int(arg("launches", "10"))!
    let count = Int(arg("n", "2000"))!
    DispatchQueue.global(qos: .userInitiated).async {
        // Cold starts.
        var startS: [Double] = [], readyS: [Double] = [], pongS: [Double] = []
        for _ in 0..<launches {
            guard let b = spawnBlock() else { return }
            let sem = DispatchSemaphore(value: 0)
            var tStart = 0.0, tReady = 0.0, tPong = 0.0
            b.channel.onMessage = { m in
                switch m {
                case let .hello(stage, _, _):
                    if stage == "start" { tStart = now() } else { tReady = now(); b.channel.send(.ping(seq: 1, onMain: true)) }
                case .pong: tPong = now(); sem.signal()
                default: break
                }
            }
            let exitSem = DispatchSemaphore(value: 0)
            let src = watchExit(b.pid) { _, _ in exitSem.signal() }
            b.channel.start()
            _ = sem.wait(timeout: .now() + 5)
            startS.append(tStart - b.tSpawn); readyS.append(tReady - b.tSpawn); pongS.append(tPong - b.tSpawn)
            b.channel.send(.quit)
            _ = exitSem.wait(timeout: .now() + 2)
            _ = src
            b.channel.close()
        }
        print("RESULT cold spawn->first message (before NSApplication) \(Stats(startS).line)")
        print("RESULT cold spawn->NSApplication didFinishLaunching \(Stats(readyS).line)")
        print("RESULT cold spawn->first main-thread reply \(Stats(pongS).line)")

        // Warm round trips.
        guard let b = spawnBlock() else { return }
        let sem = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        b.channel.onMessage = { m in
            switch m {
            case let .hello(stage, _, _): if stage == "ready" { ready.signal() }
            case .pong: sem.signal()
            default: break
            }
        }
        b.channel.start()
        _ = ready.wait(timeout: .now() + 5)
        for onMain in [false, true] {
            for i in 0..<100 { b.channel.send(.ping(seq: i, onMain: onMain)); sem.wait() }
            var v: [Double] = []
            for i in 0..<count {
                let t = now()
                b.channel.send(.ping(seq: i, onMain: onMain))
                sem.wait()
                v.append(now() - t)
            }
            print("RESULT rtt \(onMain ? "block main thread" : "block reader thread (transport floor)") \(Stats(v).line)")
        }
        let pid = b.pid
        DispatchQueue.main.async {
            measureIdle(pid: pid, label: "block(no window, NSApplication running)") {
                b.channel.send(.quit)
                after(0.3) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) }; exit(0) }
            }
        }
    }
}

switch mode {
case "rtt": runRTT()
case "view": MainActor.assumeIsolated { runView() }
case "crash": MainActor.assumeIsolated { runCrash() }
case "hang": MainActor.assumeIsolated { runHang() }
case "manual": MainActor.assumeIsolated { runManual() }
default: log("unknown mode \(mode)"); exit(1)
}
app.run()
