import AppKit
import Darwin
import SpikeShared

// Process start, resource use, window-server checks, own-window capture.

struct Spawned {
    let pid: pid_t
    let channel: Channel
    let tSpawn: Double
}

/// Start spike-block with one end of a socketpair as its fd 3.
func spawnBlock() -> Spawned? {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
    let path = URL(fileURLWithPath: Bundle.main.executablePath!).deletingLastPathComponent()
        .appendingPathComponent("spike-block").path
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_adddup2(&fa, fds[1], 3)
    posix_spawn_file_actions_addinherit_np(&fa, 0)
    posix_spawn_file_actions_addinherit_np(&fa, 1)
    posix_spawn_file_actions_addinherit_np(&fa, 2)
    posix_spawn_file_actions_addinherit_np(&fa, 3)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    // Only fds 0-3 reach the block.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
    let t = now()
    let rc = posix_spawn(&pid, path, &fa, &attr, argv, environ)
    posix_spawn_file_actions_destroy(&fa)
    posix_spawnattr_destroy(&attr)
    close(fds[1])
    guard rc == 0 else { log("posix_spawn failed \(rc)"); close(fds[0]); return nil }
    return Spawned(pid: pid, channel: Channel(fd: fds[0]), tSpawn: t)
}

/// Watch for the process to exit; reaps it. Handler gets the exit time.
func watchExit(_ pid: pid_t, _ handler: @escaping (Double, Int32) -> Void) -> DispatchSourceProcess {
    let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .userInteractive))
    src.setEventHandler {
        let t = now()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        handler(t, status)
        src.cancel()
    }
    src.resume()
    return src
}

struct Usage {
    let footprintMB: Double
    let residentMB: Double
    let cpuSeconds: Double
}

private let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

func usage(of pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard rc == 0 else { return nil }
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    let ns = ticks * Double(timebase.numer) / Double(timebase.denom)
    return Usage(footprintMB: Double(info.ri_phys_footprint) / 1_048_576,
                 residentMB: Double(info.ri_resident_size) / 1_048_576,
                 cpuSeconds: ns / 1e9)
}

/// Idle resource use of `pid` over `seconds`, sampled on a background thread.
func measureIdle(pid: pid_t, label: String, seconds: Double = 5, done: @escaping () -> Void) {
    DispatchQueue.global().async {
        guard let a = usage(of: pid) else { print("RESULT \(label) usage: unavailable"); DispatchQueue.main.async(execute: done); return }
        Thread.sleep(forTimeInterval: seconds)
        guard let b = usage(of: pid) else { DispatchQueue.main.async(execute: done); return }
        let cpu = (b.cpuSeconds - a.cpuSeconds) / seconds * 100
        print(String(format: "RESULT %@ idle: footprint=%.1f MB resident=%.1f MB cpu=%.2f %% (over %.0f s)",
                     label, b.footprintMB, b.residentMB, cpu, seconds))
        DispatchQueue.main.async(execute: done)
    }
}

/// On-screen windows, front to back, as the window server lists them.
struct WinInfo { let number: Int; let pid: Int32; let layer: Int; let alpha: Double; let bounds: CGRect; let index: Int }

func onScreenWindows() -> [WinInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.enumerated().compactMap { i, d in
        guard let n = d[kCGWindowNumber as String] as? Int, let p = d[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        var r = CGRect.zero
        if let b = d[kCGWindowBounds as String] as? NSDictionary { r = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero }
        return WinInfo(number: n, pid: p, layer: d[kCGWindowLayer as String] as? Int ?? 0,
                       alpha: d[kCGWindowAlpha as String] as? Double ?? 1, bounds: r, index: i)
    }
}

// CGWindowListCreateImage is unavailable in the macOS 26 Swift SDK; look it up
// at run time. Used only on this process's own window.
private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
private let createImage: CreateImageFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: CreateImageFn.self)
}()

private typealias FromArrayFn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
private let createImageFromArray: FromArrayFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
    return unsafeBitCast(sym, to: FromArrayFn.self)
}()

/// Capture one window (window server composite, so it includes CALayerHost
/// content). Saves a PNG under .build/captures and returns the fraction of
/// pixels in `rect` (window-local, top-left origin, points) that are bright.
@discardableResult
func captureWindow(_ number: Int, also extra: Int? = nil, name: String, brightIn rect: CGRect?) -> String {
    guard let fn = createImage, let fromArray = createImageFromArray else { return "capture: CGWindowListCreateImage missing" }
    // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1, BestResolution = 8
    var image: CGImage?
    if let extra {
        // Composite of the host panel and the block's window (another process).
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(extra)), UnsafeRawPointer(bitPattern: UInt(number))]
        let arr = CFArrayCreate(nil, &ids, 2, nil)!
        image = fromArray(.null, arr, 1 | 8)?.takeRetainedValue()
    } else {
        image = fn(.null, 8, UInt32(number), 1 | 8)?.takeRetainedValue()
    }
    guard let img = image else { return "capture: nil image (no permission?)" }
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/captures")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(name).png")
    if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }
    var frac = Double.nan
    if let rect {
        let scale = Double(img.width) / Double(NotchLayout.panelSize.width)
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        if let crop = img.cropping(to: px) {
            let w = crop.width, h = crop.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            if let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
                var bright = 0
                for i in stride(from: 0, to: buf.count, by: 4) where Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) > 300 { bright += 1 }
                frac = Double(bright) / Double(w * h)
            }
        }
    }
    return String(format: "capture %@: %dx%d px, bright pixels in content area = %.2f %%, saved .build/captures/%@.png",
                  name, img.width, img.height, frac * 100, name)
}
