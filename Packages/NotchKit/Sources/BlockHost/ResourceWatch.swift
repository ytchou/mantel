import Darwin
import Foundation
import NotchCore

/// One reading of a process: its memory footprint and the processor time it
/// has used since it started.
struct ResourceSample: Sendable, Equatable {
    var memoryBytes: UInt64
    var processorNanoseconds: UInt64
}

/// Reads a process by id; nil when it cannot be read (it has ended).
typealias ResourceSampler = @Sendable (pid_t) -> ResourceSample?

/// Samples one block process every `interval` and reports a runaway.
///
/// Over `memoryLimit` at one sample, or over `processorLimit` of one core
/// for `processorSamplesOver` samples in a row (a sample at or under the
/// limit starts the count again), it calls `onBreach` with the reason in the
/// user's words and stops. Each sample is passed to `onSample`. A sample that
/// fails ends the watch quietly: the process is gone, and the stand-in
/// learns that from its socket.
// The limits are the same for every block: 500 MB and half a core for two
// minutes leave room for the on-device model and Quick Look thumbnails,
// and stop a leak or a busy loop long before the Mac slows down. Sampling
// every 30 s means a leak may grow for up to 30 s past the limit. Upgrade
// path: limits per block in the manifest, approved with the package, and a
// shorter interval when a block comes close to a limit.
@MainActor
final class ResourceWatch {
    /// Time between samples.
    nonisolated static let interval: Duration = .seconds(30)
    /// More memory than this at one sample stops the block.
    nonisolated static let memoryLimit: UInt64 = 500 * 1024 * 1024
    /// More of one core than this, averaged over one interval, counts as over.
    nonisolated static let processorLimit = 0.5
    /// This many samples over `processorLimit` in a row stop the block: two minutes.
    nonisolated static let processorSamplesOver = 4

    nonisolated static let memoryReason = "it used more than \(memoryLimit / 1024 / 1024) MB of memory"
    nonisolated static let processorReason = "it kept more than half a processor core busy for \(Int(interval.components.seconds) * processorSamplesOver / 60) minutes"

    private let pid: pid_t
    private let sampler: ResourceSampler
    private let clock: BlockClock
    private let onSample: @MainActor (BlockUsage) -> Void
    private let onBreach: @MainActor (String) -> Void
    private var task: Task<Void, Never>?
    /// The last sample and when it was taken, on `clock`.
    private var previous: (sample: ResourceSample, at: Duration)?
    /// Samples over `processorLimit` in a row.
    private var samplesOver = 0

    /// - Parameters:
    ///   - pid: the block's process.
    ///   - sampler: reads the process; the app uses `processUsage`.
    ///   - clock: times the samples. The app uses the stand-in's clock, which
    ///     stops while the Mac sleeps.
    init(
        pid: pid_t, sampler: @escaping ResourceSampler = ResourceWatch.processUsage, clock: BlockClock,
        onSample: @escaping @MainActor (BlockUsage) -> Void, onBreach: @escaping @MainActor (String) -> Void
    ) {
        self.pid = pid
        self.sampler = sampler
        self.clock = clock
        self.onSample = onSample
        self.onBreach = onBreach
    }

    /// Takes the first sample, which only sets the starting point, and then
    /// one every `interval`. Does nothing when the process cannot be read.
    func start() {
        stop()
        guard let first = sampler(pid) else { return }
        previous = (first, clock.now())
        samplesOver = 0
        let clock = self.clock
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(Self.interval) } catch { return }
                guard let self, !Task.isCancelled, self.takeSample() else { return }
            }
        }
    }

    /// Takes no more samples.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// One sample, judged. False ends the watch.
    private func takeSample() -> Bool {
        guard let sample = sampler(pid) else {
            stop()
            return false
        }
        let now = clock.now()
        var fraction = 0.0
        if let previous {
            let elapsed = Double((now - previous.at).components.seconds) * 1e9
                + Double((now - previous.at).components.attoseconds) / 1e9
            let before = previous.sample.processorNanoseconds
            let used = sample.processorNanoseconds >= before ? Double(sample.processorNanoseconds - before) : 0
            fraction = elapsed > 0 ? used / elapsed : 0
        }
        previous = (sample, now)
        onSample(BlockUsage(memoryBytes: sample.memoryBytes, processorFraction: fraction))

        samplesOver = fraction > Self.processorLimit ? samplesOver + 1 : 0
        let reason: String? = if sample.memoryBytes > Self.memoryLimit {
            Self.memoryReason
        } else if samplesOver >= Self.processorSamplesOver {
            Self.processorReason
        } else {
            nil
        }
        guard let reason else { return true }
        stop()
        onBreach(reason)
        return false
    }

    /// The process's memory footprint (`ri_phys_footprint`, what Activity
    /// Monitor shows as Memory) and its user plus system time, from
    /// `proc_pid_rusage`. Nil when the process cannot be read.
    nonisolated static func processUsage(_ pid: pid_t) -> ResourceSample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // The times are in Mach time units, not nanoseconds, on Apple silicon.
        let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
        return ResourceSample(memoryBytes: info.ri_phys_footprint,
                              processorNanoseconds: UInt64(ticks * timebase))
    }

    /// Nanoseconds per Mach time unit.
    private nonisolated static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()
}
