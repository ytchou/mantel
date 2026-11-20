import BlockWire
import Darwin
import Foundation
import os

/// Errors starting a block process.
public enum BlockProcessError: Error, Equatable, Sendable {
    /// `socketpair` failed with this errno.
    case socketFailed(Int32)
    /// `posix_spawn` failed with this error number.
    case spawnFailed(Int32)
}

/// The clock a stand-in times its heartbeat and failures on, read as time
/// since the clock was made. The app uses `suspending`; tests pass a clock
/// they move by hand.
public struct BlockClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    public init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(until: clock.now.advanced(by: $0), tolerance: nil) }
    }

    /// Stops while the Mac sleeps, so the time asleep is never read as a hang.
    public static var suspending: BlockClock { BlockClock(SuspendingClock()) }
}

/// One running block process and the socket to it.
///
/// The block gets one end of a socket pair as fd 3, `/dev/null` as stdin and
/// stdout (protocol traffic never uses them), and the app's stderr. Its
/// environment is minimal: `PATH`, `HOME`, `TMPDIR` and
/// `TOPNOTCH_BLOCK_GENERATION`, which the kit uses for `hello`.
///
/// It is the `Transport` to the block. `close()` ends the process: the socket
/// closes (the kit exits when it sees that), then SIGTERM, then SIGKILL.
public final class BlockProcess: Transport, @unchecked Sendable {
    // @unchecked: `pid` and `socket` are immutable; `lock` guards `exited`
    // and is held for every `waitpid` and `kill`, so a signal never reaches a
    // reused pid.
    public let pid: pid_t
    private let socket: SocketTransport
    private let lock = NSLock()
    private var exited = false
    private var exitSource: (any DispatchSourceProcess)?

    static let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "blocks")

    private init(pid: pid_t, socket: SocketTransport) {
        self.pid = pid
        self.socket = socket
    }

    // MARK: Spawn

    /// Starts `executable` with the socket as fd 3 and `generation` in its
    /// environment, without a sandbox. Blocks the app runs use
    /// `spawn(executable:generation:sandbox:)`.
    public static func spawn(executable: URL, generation: Int) throws(BlockProcessError) -> BlockProcess {
        try spawn(executable: executable, generation: generation, sandbox: nil)
    }

    /// The tool that applies a sandbox profile and then runs the block in
    /// its own place: the process id stays the block's after the exec.
    // Deprecated by Apple but present on macOS 26. If it goes, a small
    // launcher that calls `sandbox_init_with_parameters` and then execs the
    // block replaces it, with no protocol change.
    static let sandboxExec = "/usr/bin/sandbox-exec"

    /// Starts `executable` with the socket as fd 3 and `generation` in its
    /// environment. With `sandbox`, the block runs under that profile through
    /// `sandbox-exec`, and its `TMPDIR` is the profile's temporary folder.
    /// Create the profile's folders before building it.
    static func spawn(executable: URL, generation: Int, sandbox: SandboxProfile?) throws(BlockProcessError) -> BlockProcess {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw .socketFailed(errno) }
        // Neither end may leak into other processes the app starts; the
        // child gets its end through the dup2 below.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 3)
        // Needed when fds[1] is already 3: dup2 onto itself keeps CLOEXEC.
        posix_spawn_file_actions_addinherit_np(&actions, 3)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only fds 0 to 3 reach the block.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let path = sandbox == nil ? executable.path : sandboxExec
        let arguments = sandbox.map { [sandboxExec, "-p", $0.text, executable.path] } ?? [executable.path]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let temporary = sandbox.map { SandboxProfile.resolvedPath($0.temporaryFolder) }
        let envp: [UnsafeMutablePointer<CChar>?] = environment(generation: generation, temporaryFolder: temporary)
            .map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        Darwin.close(fds[1])
        guard result == 0 else {
            Darwin.close(fds[0])
            throw .spawnFailed(result)
        }

        let process = BlockProcess(pid: pid, socket: SocketTransport(fd: fds[0], sendTimeout: sendTimeout))
        process.watchExit()
        log.info("block process \(pid) started: \(executable.path, privacy: .public), generation \(generation), sandboxed: \(sandbox != nil)")
        return process
    }

    /// The environment a block starts with. The app's own is not passed on.
    /// `temporaryFolder` is the `TMPDIR`; nil keeps the app's.
    static func environment(generation: Int, temporaryFolder: String? = nil) -> [String] {
        let own = ProcessInfo.processInfo.environment
        return [
            "PATH=" + (own["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"),
            "HOME=" + (own["HOME"] ?? NSHomeDirectory()),
            "TMPDIR=" + (temporaryFolder ?? own["TMPDIR"] ?? NSTemporaryDirectory()),
            "TOPNOTCH_BLOCK_GENERATION=\(generation)",
        ]
    }

    // MARK: Transport

    public var frames: AsyncThrowingStream<Data, any Error> { socket.frames }

    public func send(_ body: Data) throws(FramingError) {
        try socket.send(body)
    }

    /// Closes the socket and ends the process off the caller's thread.
    public func close() {
        socket.close()
        DispatchQueue.global(qos: .utility).async { [self] in terminate() }
    }

    // MARK: Ending

    /// True once the process has exited and been reaped.
    public var hasExited: Bool { lock.withLock { exited } }

    /// Ends the process and waits for it, as `terminate(_:)` does.
    public func terminate() {
        Self.terminate([self])
    }

    /// Ends every process together and waits for them: each socket closes,
    /// then after 0.5 s SIGTERM to those still running, then after 1 s more
    /// SIGKILL. Blocks the caller for at most about 2.5 s in total, however
    /// many processes; it returns as soon as all have exited. For app quit,
    /// where waiting is the point.
    public static func terminate(_ processes: [BlockProcess]) {
        for process in processes { process.socket.close() }
        var running = waitForExit(processes, seconds: 0.5)
        guard !running.isEmpty else { return }
        for process in running { process.signal(SIGTERM) }
        running = waitForExit(running, seconds: 1)
        guard !running.isEmpty else { return }
        for process in running { process.signal(SIGKILL) }
        for process in waitForExit(running, seconds: 1) {
            log.error("block process \(process.pid) did not exit after SIGKILL")
        }
    }

    private func signal(_ signal: Int32) {
        lock.withLock {
            guard !exited else { return }
            Darwin.kill(pid, signal)
        }
    }

    /// Waits up to `seconds` for the processes to exit. Returns those still running.
    private static func waitForExit(_ processes: [BlockProcess], seconds: Double) -> [BlockProcess] {
        let deadline = Date().addingTimeInterval(seconds)
        var running = processes
        while true {
            running.removeAll { $0.reap() }
            if running.isEmpty || Date() >= deadline { return running }
            usleep(5_000)
        }
    }

    /// Collects the exit status if the process has ended. True once exited.
    @discardableResult
    private func reap() -> Bool {
        lock.withLock {
            if exited { return true }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) {
                exited = true
                Self.log.info("block process \(self.pid) exited, status \(status)")
            }
            return exited
        }
    }

    /// Reaps the process as soon as it exits, so it never lingers as a zombie.
    private func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if reap() { lock.withLock { exitSource?.cancel() } }
        }
        lock.withLock { exitSource = source }
        source.resume()
        // It may have exited before the source was watching.
        if reap() { lock.withLock { exitSource?.cancel() } }
    }

    // MARK: Heartbeat

    /// Time between pings.
    static let pingInterval: Duration = .seconds(1)
    /// No pong for this long, after `welcome`, is a hang.
    static let hangAfter: Duration = .seconds(3)
    /// Before `welcome`, no hello or pong for this long is a hang: a first
    /// start may be slow while the Mac is busy.
    static let startAllowance: Duration = .seconds(10)
    /// How long one write to the block may wait for it to read. A block
    /// that does not read for this long is a failure, so a stopped block
    /// never freezes the app's main thread.
    static let sendTimeout: Duration = .milliseconds(500)

    /// Calls `tick` on the main actor every `pingInterval` of `clock` until
    /// `tick` returns false or the task is cancelled. `tick` sends the ping
    /// and judges the hang; this loop only keeps time.
    static func heartbeat(clock: BlockClock, tick: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(pingInterval)
                } catch {
                    return
                }
                if Task.isCancelled || !tick() { return }
            }
        }
    }

    // MARK: Reading

    /// Reads and decodes frames off the main actor and hands each one to the
    /// main actor, in order. `ended` runs once, with the error when a frame
    /// was bad, or nil when the other side closed. Cancel the task to stop
    /// delivery.
    static func readFrames(
        from transport: any Transport,
        deliver: @escaping @MainActor (Envelope<BlockToHost>) -> Void,
        ended: @escaping @MainActor ((any Error)?) -> Void
    ) -> Task<Void, Never> {
        let envelopes = transport.envelopes(of: BlockToHost.self)
        return Task.detached(priority: .userInitiated) {
            do {
                for try await envelope in envelopes {
                    if Task.isCancelled { return }
                    await MainActor.run { deliver(envelope) }
                }
                if Task.isCancelled { return }
                await MainActor.run { ended(nil) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { ended(error) }
            }
        }
    }
}
