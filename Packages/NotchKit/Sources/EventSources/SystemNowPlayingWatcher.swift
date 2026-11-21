import AppKit
import Darwin
import NotchCore
import os

/// Publishes `NowPlayingChanged` for whatever macOS shows as Now Playing:
/// YouTube in a browser, podcasts, video players, and Spotify and Music too,
/// with artwork. Needs no permission and shows no prompt.
///
/// How: macOS 15.4 and later answer the private MediaRemote framework only
/// for Apple-signed processes. The helper library (`Helpers/NowPlayingHelper.m`,
/// built into the app's Frameworks folder) is loaded into `/usr/bin/perl`,
/// which is Apple-signed, and prints one JSON line per change.
///
/// Cost: MediaRemote is undocumented. A macOS update can stop this; the
/// helper then exits or prints nothing, and only this source goes quiet.
/// Spotify and Music keep working through `PlayerNotificationWatcher`.
@MainActor
public final class SystemNowPlayingWatcher {
    private let runtime: NotchRuntime
    private let helperURL: URL?
    private(set) var process: Process?
    private var input: Pipe?
    private var translator = SystemNowPlayingTranslator()
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "nowplaying")

    static let helperSymbol = "topnotch_nowplaying_stream"
    /// Loads the helper and calls its stream function, which runs until stdin closes.
    static let perlScript = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "\(helperSymbol)") or die "no symbol";
    DynaLoader::dl_install_xsub("main::stream", $sym);
    stream();
    """

    /// `helperURL`: the built helper library, nil when it is missing.
    public init(runtime: NotchRuntime, helperURL: URL?) {
        self.runtime = runtime
        self.helperURL = helperURL
    }

    public func start() {
        guard process == nil else { return }
        guard let helperURL, FileManager.default.fileExists(atPath: helperURL.path) else {
            log.error("now-playing helper missing; other players are not watched")
            return
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = ["-e", Self.perlScript, helperURL.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        let lines = LineSplitter()
        let deliver: @MainActor @Sendable (Data) -> Void = { [weak self] line in self?.received(line) }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in lines.append(data) {
                Task { @MainActor in deliver(line) }
            }
        }
        let log = self.log
        process.terminationHandler = { process in
            log.info("now-playing helper ended, status \(process.terminationStatus)")
        }
        do {
            try process.run()
            self.process = process
            self.input = input
            log.info("now-playing helper started")
        } catch {
            log.error("now-playing helper failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    public func stop() {
        // Closing its stdin ends the helper.
        try? input?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        input = nil
    }

    private func received(_ line: Data) {
        guard let decoded = try? JSONDecoder().decode(SystemNowPlayingLine.self, from: line) else { return }
        for event in translator.events(for: decoded, appName: Self.appName(pid: decoded.pid)) {
            runtime.publish(event)
        }
    }

    /// The app's name for a process: its own, or the `.app` folder it runs from
    /// (a browser can play from a helper process), or the program's file name.
    static func appName(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return appName(path: String(cString: buffer))
    }

    nonisolated static func appName(path: String) -> String? {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return parts.last.map(String.init)
    }
}

/// One line from the helper.
struct SystemNowPlayingLine: Decodable, Equatable {
    var pid: Int32
    var playing: Bool
    var title: String?
    var artist: String?
    var album: String?
    /// Base64 image data.
    var artwork: String?
}

/// Turns helper lines into events. macOS has one Now Playing app at a time,
/// so when it changes, the previous app is reported stopped: nothing else
/// would tell a block that it is no longer the one playing.
struct SystemNowPlayingTranslator {
    private var lastPlayer: String?

    mutating func events(for line: SystemNowPlayingLine, appName: String?) -> [NowPlayingChanged] {
        var events: [NowPlayingChanged] = []
        let hasTrack = !(line.title ?? "").isEmpty
        if let last = lastPlayer, last != appName || !hasTrack {
            events.append(NowPlayingChanged(player: last, state: .stopped))
            lastPlayer = nil
        }
        guard let appName, hasTrack else { return events }
        lastPlayer = appName
        events.append(NowPlayingChanged(
            player: appName,
            state: line.playing ? .playing : .paused,
            title: line.title ?? "",
            artist: line.artist ?? "",
            album: line.album ?? "",
            artwork: line.artwork.flatMap { Data(base64Encoded: $0) }
        ))
        return events
    }
}

/// Splits a byte stream into lines. Used only from the pipe's handler, which
/// runs one call at a time; the lock makes that explicit.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
