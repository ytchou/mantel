import Foundation
import Testing
@testable import BlockHost
import NotchCore

/// The reasons and usage a watch reported.
@MainActor
final class WatchReports {
    var breaches: [String] = []
    var usage: [BlockUsage] = []
}

@MainActor
struct ResourceWatchTests {
    private let megabyte: UInt64 = 1024 * 1024

    private func watch(_ samples: FakeSamples, _ clock: ManualClock, _ reports: WatchReports) -> ResourceWatch {
        ResourceWatch(pid: 4242, sampler: samples.sampler, clock: BlockClock(clock),
                      onSample: { reports.usage.append($0) }, onBreach: { reports.breaches.append($0) })
    }

    @Test func memoryOverTheLimitStopsTheBlock() async {
        let samples = FakeSamples(memoryBytes: 500 * megabyte)
        let clock = ManualClock()
        let reports = WatchReports()
        let watch = watch(samples, clock, reports)
        watch.start()

        // At the limit is not over it.
        await nextSample(clock, samples)
        #expect(reports.breaches.isEmpty)

        samples.setMemory(500 * megabyte + 1)
        await nextSample(clock, samples)
        #expect(reports.breaches == ["it used more than 500 MB of memory"])

        // Stopped: no more samples.
        let calls = samples.calls
        clock.advance(by: ResourceWatch.interval * 2)
        await settle()
        #expect(samples.calls == calls)
        #expect(clock.sleeperCount == 0)
    }

    @Test func processorOverTheLimitForTwoMinutesStopsTheBlock() async {
        let samples = FakeSamples()
        let clock = ManualClock()
        let reports = WatchReports()
        let watch = watch(samples, clock, reports)
        watch.start()

        // Three over, a low one, three over: never four in a row.
        for fraction in [0.6, 0.6, 0.6, 0.1, 0.6, 0.6, 0.6] {
            samples.busy(fraction)
            await nextSample(clock, samples)
        }
        #expect(reports.breaches.isEmpty)

        samples.busy(0.6)
        await nextSample(clock, samples)
        #expect(reports.breaches == ["it kept more than half a processor core busy for 2 minutes"])
        watch.stop()
    }

    /// A sample that fails (the process is gone) ends the watch, with no
    /// usage and no breach.
    @Test func aSampleThatFailsEndsTheWatch() async {
        let clock = ManualClock()
        let reports = WatchReports()
        let calls = Counter()
        let sampler: ResourceSampler = { _ in
            calls.increment()
            return calls.value == 1 ? ResourceSample(memoryBytes: 1, processorNanoseconds: 0) : nil
        }
        let watch = ResourceWatch(pid: 4242, sampler: sampler, clock: BlockClock(clock),
                                  onSample: { reports.usage.append($0) }, onBreach: { reports.breaches.append($0) })
        watch.start()
        await waitUntil { clock.sleeperCount > 0 }
        clock.advance(by: ResourceWatch.interval)
        await waitUntil { calls.value == 2 }
        clock.advance(by: ResourceWatch.interval)
        await settle()

        #expect(calls.value == 2)
        #expect(clock.sleeperCount == 0)
        #expect(reports.usage.isEmpty && reports.breaches.isEmpty)
    }

    @Test func theDefaultSamplerReadsThisProcess() {
        let sample = ResourceWatch.processUsage(getpid())
        #expect((sample?.memoryBytes ?? 0) > 0)
        #expect((sample?.processorNanoseconds ?? 0) > 0)
    }

    // MARK: In the stand-in

    @Test func usageIsPublishedForEachSample() async throws {
        let samples = FakeSamples(memoryBytes: 200 * megabyte)
        let rig = Rig(samples: samples)
        try await rig.process.start()
        // Running, but not sampled yet.
        #expect(rig.block.usage == nil)

        samples.busy(0.25)
        await rig.sample(samples)
        #expect(rig.block.usage == BlockUsage(memoryBytes: 200 * megabyte, processorFraction: 0.25))

        samples.setMemory(300 * megabyte)
        samples.busy(0.1)
        await rig.sample(samples)
        let usage = try #require(rig.block.usage)
        #expect(usage.memoryBytes == 300 * megabyte)
        #expect(abs(usage.processorFraction - 0.1) < 0.0001)

        rig.block.stop()
        #expect(rig.block.usage == nil)
    }

    @Test func theWatchStopsWithTheProcess() async throws {
        let samples = FakeSamples()
        let rig = Rig(samples: samples)
        try await rig.process.start()
        await rig.sample(samples)

        rig.block.stop()
        let calls = samples.calls
        rig.resourceClock.advance(by: ResourceWatch.interval * 3)
        await settle()

        #expect(samples.calls == calls)
        #expect(rig.resourceClock.sleeperCount == 0)
    }
}

/// A count a sendable closure can raise.
final class Counter: @unchecked Sendable {
    // @unchecked: `lock` guards `count`.
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
