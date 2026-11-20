import AppKit
import RemoteLayer
import SpikeShared
import SwiftUI

enum Kind: String, CaseIterable { case hover, click, drag, resize }

struct Sample {
    var t0 = Double.nan       // input event arrived in the process that owns the input surface
    var tRecv = Double.nan    // block received the message (options 2, 3)
    var tReply = Double.nan   // host received the block's description (option 1)
    var tBody = Double.nan    // SwiftUI evaluated the view with the new state
    var tCommit = Double.nan  // CA transaction with the new layers committed
    var tFrame = Double.nan   // estimated on-glass time (next display-link target)
    var tHostCommit = Double.nan // resize: host's own shape commit
    var commit: Double { tCommit - t0 }
    var frame: Double { tFrame - t0 }
}

@MainActor
final class HostModel: ObservableObject {
    @Published var expanded = true
    @Published var showNodes = true
    @Published var placeholder: String?
    @Published var version = 0
    var animate = false
}

struct HostRoot: View {
    @ObservedObject var host: HostModel
    let nodes: ViewModel
    let layout: NotchLayout

    var body: some View {
        let _ = Probe.bodyEvaluated(version: host.version)
        let s = layout.shapeSize(expanded: host.expanded)
        let c = layout.contentSize(expanded: host.expanded)
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 22, bottomTrailingRadius: 22,
                                   topTrailingRadius: 0, style: .continuous)
                .fill(Color.black)
                .frame(width: s.width, height: s.height)
                .overlay(alignment: .bottom) {
                    Group {
                        if host.showNodes {
                            NodeRootView(model: nodes)
                        } else if let p = host.placeholder {
                            Text(p).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: c.width, height: c.height)
                    .padding(.bottom, NotchLayout.inset)
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(host.animate ? .spring(duration: 0.3) : nil, value: host.expanded)
    }
}

/// The host: a notch-like panel plus, for options 1-3, one block process.
@MainActor
final class Host {
    let option: String          // inproc | described | window | layer
    let route: String           // layer option: reparent | window
    let manual: Bool
    let layout = NotchLayout(screen: NSScreen.screens.first!)
    let hostModel = HostModel()
    let nodesModel = ViewModel()
    var state = DemoState()
    var panel: SpikePanel!
    var inputView: InputView!
    var layerHostView: NSView?
    var layerHost: CALayer?

    var block: Spawned?
    var exitSource: DispatchSourceProcess?
    var blockWindowNumber: Int?
    var seq = 0
    var waiting: [Int: (Sample) -> Void] = [:]
    var partial: [Int: Sample] = [:]
    var pendingClick: Int?
    var onBlockClosed: ((Double) -> Void)?
    var onBlockExit: ((Double, Int32) -> Void)?
    var onPong: ((Int) -> Void)?
    var onReady: (() -> Void)?

    init(option: String, route: String, manual: Bool) {
        self.option = option; self.route = route; self.manual = manual
        hostModel.animate = manual
        hostModel.expanded = !manual   // manual: start collapsed, hover expands
        hostModel.showNodes = option == "inproc" || option == "described"
    }

    func showPanel() {
        panel = SpikePanel(frame: layout.panelFrame, level: .statusBar)
        let iv = InputView(frame: CGRect(origin: .zero, size: NotchLayout.panelSize))
        iv.wantsLayer = true
        let h = NSHostingView(rootView: HostRoot(host: hostModel, nodes: nodesModel, layout: layout))
        h.frame = iv.bounds
        h.autoresizingMask = [.width, .height]
        iv.addSubview(h)
        iv.acceptRealEvents = manual
        iv.onMouseDown = { [weak self] t, _ in self?.clicked(at: t) }
        if manual && option != "window" {
            iv.enableDrops()
            iv.onDrag = { [weak self] name, dropped in
                guard let self else { return }
                self.seq += 1
                let s = self.seq
                self.route(dropped ? .drop([name]) : .dragOver(name), seq: s, t0: now()) { self.report("drag(manual)", $0) }
            }
        }
        panel.contentView = iv
        inputView = iv
        panel.orderFrontRegardless()
        FrameClock.install(on: iv)
    }

    // MARK: block process

    func startBlock(_ ready: @escaping () -> Void) {
        guard let b = spawnBlock() else { fatalError("spawn failed") }
        block = b
        onReady = ready
        b.channel.onMessage = { [weak self] msg in
            let tArrive = now()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(msg, at: tArrive) } }
        }
        b.channel.onClose = { [weak self] t in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onBlockClosed?(t) } }
        }
        b.channel.start()
        exitSource = watchExit(b.pid) { [weak self] t, status in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onBlockExit?(t, status) } }
        }
    }

    func setupBlock() {
        let rect = layout.toScreen(layout.contentRectInPanel(expanded: hostModel.expanded))
        block?.channel.send(.setup(option: option, frame: Rect(rect), level: NSWindow.Level.statusBar.rawValue + 1,
                                   route: route, manual: manual))
    }

    func received(_ msg: Msg, at tArrive: Double) {
        switch msg {
        case let .hello(stage, _, _):
            if stage == "ready" { let r = onReady; onReady = nil; r?() }
        case let .pong(seq):
            onPong?(seq)
        case let .describe(seq, nodes, t0):
            // Option 1: draw the block's description in the host's SwiftUI.
            guard let done = waiting.removeValue(forKey: seq) else { return }
            var s = Sample(); s.t0 = t0; s.tReply = tArrive
            Probe.expect(version: seq) { b, c, f in s.tBody = b; s.tCommit = c; s.tFrame = f; done(s) }
            nodesModel.nodes = nodes
            nodesModel.version = seq
        case let .committed(seq, t0, tRecv, tBody, tCommit, tFrame):
            var s = partial.removeValue(forKey: seq) ?? Sample()
            s.t0 = t0; s.tRecv = tRecv; s.tBody = tBody; s.tCommit = tCommit; s.tFrame = tFrame
            if let done = waiting.removeValue(forKey: seq) { done(s) } else if manual { report("block input", s) }
        case let .layerContext(id, route):
            attachLayerHost(contextId: id, route: route)
            let r = onReady; onReady = nil; r?()
        case let .window(number):
            blockWindowNumber = number
            let r = onReady; onReady = nil; r?()
        case let .log(s):
            log("block: \(s)")
        default:
            break
        }
    }

    func attachLayerHost(contextId: UInt32, route: String) {
        guard contextId != 0, let lh = RLMakeLayerHost(contextId) else {
            print("RESULT layer: no context id or no CALayerHost class (contextId=\(contextId))"); return
        }
        let v = NSView(frame: layout.contentRectInPanel(expanded: hostModel.expanded))
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true   // host-side corner clipping of remote content
        lh.frame = v.bounds
        lh.anchorPoint = .zero
        lh.position = .zero
        v.layer?.addSublayer(lh)
        inputView.addSubview(v)
        layerHostView = v; layerHost = lh
    }

    // MARK: input

    /// One input of `kind`; `done` gets the sample (NaNs on timeout).
    func perform(_ kind: Kind, _ done: @escaping (Sample) -> Void) {
        seq += 1
        let s = seq
        var finished = false
        let once: (Sample) -> Void = { smp in if !finished { finished = true; done(smp) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.waiting.removeValue(forKey: s); once(Sample())
        }
        switch kind {
        case .hover:
            // As if the pointer poll found the pointer inside/outside the shape.
            route(.hover(!state.inside), seq: s, t0: now(), once)
        case .click:
            if option == "window" {
                waiting[s] = once
                block?.channel.send(.injectClick(seq: s))
            } else {
                pendingClick = s
                waiting[s] = once
                inputView.injectClick()
            }
        case .drag:
            if option == "window" {
                waiting[s] = once
                block?.channel.send(.injectDragOver(seq: s, name: "file-\(s).png"))
            } else {
                // Drag-over handler called directly (no synthetic NSDraggingInfo).
                route(.dragOver("file-\(s).png"), seq: s, t0: now(), once)
            }
        case .resize:
            resize(seq: s, t0: now(), once)
        }
    }

    func clicked(at t: Double) {
        let s: Int
        var done: ((Sample) -> Void)?
        if let p = pendingClick { s = p; pendingClick = nil; done = waiting.removeValue(forKey: p) } else { seq += 1; s = seq }
        route(.click, seq: s, t0: t, done ?? { [weak self] in self?.report("click(manual)", $0) })
    }

    func route(_ input: Input, seq s: Int, t0: Double, _ done: @escaping (Sample) -> Void) {
        if case let .hover(v) = input { state.inside = v }
        switch option {
        case "inproc":
            state.apply(input)
            Probe.expect(version: s) { b, c, f in
                var smp = Sample(); smp.t0 = t0; smp.tBody = b; smp.tCommit = c; smp.tFrame = f; done(smp)
            }
            nodesModel.nodes = state.nodes()
            nodesModel.version = s
        default:
            waiting[s] = done
            block?.channel.send(.input(seq: s, input: input, t0: t0))
        }
    }

    func resize(seq s: Int, t0: Double, _ done: @escaping (Sample) -> Void) {
        let expanded = !hostModel.expanded
        var hostSample = Sample(); hostSample.t0 = t0
        let crossProcess = option == "window" || option == "layer"
        Probe.expect(version: s) { [weak self] b, c, f in
            hostSample.tBody = b; hostSample.tCommit = c; hostSample.tFrame = f
            if crossProcess { self?.partial[s, default: Sample()].tHostCommit = c } else { done(hostSample) }
        }
        hostModel.expanded = expanded
        hostModel.version = s
        let content = layout.contentRectInPanel(expanded: expanded)
        if crossProcess {
            layerHostView?.frame = content   // same run loop pass, same CA transaction as the shape
            waiting[s] = done
            block?.channel.send(.setFrame(seq: s, frame: Rect(layout.toScreen(content)), t0: t0))
        }
    }

    func report(_ label: String, _ s: Sample) {
        print(String(format: "EVENT %@ commit=%.2f ms frame(est)=%.2f ms", label, s.commit * 1000, s.frame * 1000))
    }

    func quitBlock() {
        block?.channel.send(.quit)
    }
}

/// Run `n` inputs of each kind one after another; a short random gap between
/// inputs so they do not lock to vsync.
@MainActor
func runSeries(_ host: Host, kinds: [Kind], n: Int, done: @escaping ([Kind: [Sample]]) -> Void) {
    var results: [Kind: [Sample]] = [:]
    var ki = 0, i = 0
    func step() {
        if ki == kinds.count { done(results); return }
        let kind = kinds[ki]
        host.perform(kind) { s in
            results[kind, default: []].append(s)
            i += 1
            if i >= n { i = 0; ki += 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 + Double.random(in: 0..<0.017)) { step() }
        }
    }
    step()
}
