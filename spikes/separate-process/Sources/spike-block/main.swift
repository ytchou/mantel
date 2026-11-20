import AppKit
import RemoteLayer
import SpikeShared
import SwiftUI

// The block process. Started by spike-host with one end of a socketpair as
// fd 3. Exits when the host closes the socket.

let tStart = now()
let channel = Channel(fd: 3)
// First reply, before AppKit is even set up: measures bare process start.
channel.send(.hello(stage: "start", t: tStart, pid: getpid()))

@MainActor
final class Block: NSObject, NSApplicationDelegate {
    var state = DemoState()
    let model = ViewModel()
    var option = ""
    var manual = false
    var panel: SpikePanel?
    var inputView: InputView?
    var hosting: NSHostingView<NodeRootView>?
    var layerWindow: NSWindow?
    var remoteContext: AnyObject?
    var plainRoot: CALayer?
    var pendingClickSeq: Int?
    var manualSeq = 1_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        channel.send(.hello(stage: "ready", t: now(), pid: getpid()))
    }

    func handle(_ msg: Msg) {
        switch msg {
        case let .ping(seq, _):
            channel.send(.pong(seq: seq))
        case let .setup(option, frame, level, route, manual):
            setup(option: option, frame: frame.cg, level: level, route: route, manual: manual)
        case let .input(seq, input, t0):
            let tRecv = now()
            state.apply(input)
            if option == "described" {
                channel.send(.describe(seq: seq, nodes: state.nodes(), t0: t0))
            } else {
                show(seq: seq, t0: t0, tRecv: tRecv)
            }
        case let .injectClick(seq):
            pendingClickSeq = seq
            inputView?.injectClick()
        case let .injectDragOver(seq, name):
            // Option 2: the block window is the drop target, so a drag-over
            // starts here. Handler called directly (no synthetic NSDraggingInfo).
            let t0 = now()
            state.apply(.dragOver(name))
            show(seq: seq, t0: t0, tRecv: t0)
        case let .setFrame(seq, frame, t0):
            let tRecv = now()
            if option == "window" {
                panel?.setFrame(frame.cg, display: true)
            } else if option == "layer" {
                hosting?.setFrameSize(frame.cg.size)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                snapshotLayer?.frame = CGRect(origin: .zero, size: frame.cg.size)
                CATransaction.commit()
                layerWindow?.setFrame(frame.cg, display: true)
            }
            show(seq: seq, t0: t0, tRecv: tRecv, changeNodes: false)
        case .crash:
            fatalError("spike-block: crash requested by host")
        case let .hang(seconds):
            Thread.sleep(forTimeInterval: seconds)
        case .idle:
            FrameClock.uninstall()
        case .quit:
            exit(0)
        default:
            break
        }
    }

    func show(seq: Int, t0: Double, tRecv: Double, changeNodes: Bool = true) {
        Probe.expect(version: seq) { b, c, f in
            channel.send(.committed(seq: seq, t0: t0, tRecv: tRecv, tBody: b, tCommit: c, tFrame: f))
        }
        if changeNodes { model.nodes = state.nodes() }
        model.version = seq
        if snapshotLayer != nil { renderSnapshot() }
    }

    /// Route "snapshot": SwiftUI rendered to a bitmap with ImageRenderer and
    /// set as the contents of a bare CALayer in the remote context.
    var snapshotLayer: CALayer?
    func renderSnapshot() {
        guard let layer = snapshotLayer else { return }
        let r = ImageRenderer(content: NodeRootView(model: model).frame(width: layer.bounds.width, height: layer.bounds.height))
        r.scale = 2
        let img = r.cgImage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = img
        CATransaction.commit()
    }

    func setup(option: String, frame: CGRect, level: Int, route: String, manual: Bool) {
        self.option = option
        self.manual = manual
        model.onButton = { [weak self] _ in self?.state.clicks = 0 }
        switch option {
        case "window":
            // Option 2: the block owns a borderless non-activating window that
            // the host asked to be placed over its notch content area.
            let p = SpikePanel(frame: frame, level: NSWindow.Level(rawValue: level))
            let iv = InputView(frame: CGRect(origin: .zero, size: frame.size))
            iv.wantsLayer = true
            let h = NSHostingView(rootView: NodeRootView(model: model))
            h.frame = iv.bounds
            h.autoresizingMask = [.width, .height]
            iv.addSubview(h)
            iv.acceptRealEvents = manual
            iv.onMouseDown = { [weak self] t, _ in
                guard let self else { return }
                let seq: Int
                if let s = pendingClickSeq { seq = s; pendingClickSeq = nil } else { manualSeq += 1; seq = manualSeq }
                state.apply(.click)
                show(seq: seq, t0: t, tRecv: t)
            }
            if manual {
                iv.enableDrops()
                iv.onDrag = { [weak self] name, dropped in
                    guard let self else { return }
                    let t = now()
                    manualSeq += 1
                    state.apply(dropped ? .drop([name]) : .dragOver(name))
                    show(seq: manualSeq, t0: t, tRecv: t)
                }
            }
            p.contentView = iv
            p.ignoresMouseEvents = !manual
            p.orderFrontRegardless()
            panel = p; inputView = iv; hosting = h
            FrameClock.install(on: iv)
            channel.send(.window(number: p.windowNumber))
        case "layer":
            // Option 3 (PRIVATE API): render in this process, show in the host
            // through CAContext -> CALayerHost. The window here is invisible
            // (alpha 0, click-through); it only drives AppKit/SwiftUI updates.
            let w = SpikePanel(frame: frame, level: .normal)
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
            container.wantsLayer = true
            let h = NSHostingView(rootView: NodeRootView(model: model))
            h.frame = container.bounds
            h.wantsLayer = true
            container.addSubview(h)
            w.contentView = container
            w.orderFrontRegardless()
            layerWindow = w; hosting = h
            FrameClock.install(on: h)
            h.layoutSubtreeIfNeeded()
            var id: UInt32 = 0
            if route == "window" {
                id = RLContextIdOfLayer(h.layer!)
            } else if route == "snapshot" {
                let root = CALayer()
                root.frame = CGRect(origin: .zero, size: frame.size)
                root.isGeometryFlipped = true
                snapshotLayer = root
                renderSnapshot()
                remoteContext = RLMakeRemoteContext(root, &id) as AnyObject?
            } else if route == "plain" {
                // Diagnostic: a bare CALayer tree, no AppKit or SwiftUI.
                let root = CALayer()
                root.frame = CGRect(origin: .zero, size: frame.size)
                root.backgroundColor = NSColor.systemRed.cgColor
                let text = CATextLayer()
                text.string = "remote CALayer from pid \(getpid())"
                text.fontSize = 16
                text.foregroundColor = NSColor.white.cgColor
                text.frame = root.bounds.insetBy(dx: 12, dy: 30)
                root.addSublayer(text)
                plainRoot = root
                remoteContext = RLMakeRemoteContext(root, &id) as AnyObject?
            } else {
                // Detach the hosting view's layer from the window's layer tree
                // and make it the root of the remote context. AppKit keeps the
                // view (so SwiftUI keeps updating the layer's sublayers); the
                // window only drives the update cycle.
                let l = h.layer!
                l.removeFromSuperlayer()
                l.frame = CGRect(origin: .zero, size: frame.size)
                remoteContext = RLMakeRemoteContext(l, &id) as AnyObject?
            }
            channel.send(.log("layer route=\(route) contextId=\(id) remoteContext=\(remoteContext != nil)"))
            channel.send(.layerContext(id: id, route: route))
        default:
            break // described: no UI in the block
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let block = MainActor.assumeIsolated { Block() }
app.delegate = block
channel.onMessage = { msg in
    // Transport floor: answer reader-thread pings without touching the main thread.
    if case let .ping(seq, onMain) = msg, !onMain { channel.send(.pong(seq: seq)); return }
    DispatchQueue.main.async { MainActor.assumeIsolated { block.handle(msg) } }
}
channel.onClose = { _ in exit(0) }
channel.start()
app.run()
