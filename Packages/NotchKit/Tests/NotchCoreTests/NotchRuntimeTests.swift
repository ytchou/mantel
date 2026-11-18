import Foundation
import Observation
import Synchronization
import Testing
@testable import NotchCore

@MainActor
struct NotchRuntimeTests {
    // Rule 1
    @Test func registerActivatesEnabledBlocksAndIgnoresDuplicateIDs() {
        let runtime = NotchRuntime()
        let a = FakeBlock("a")
        let off = FakeBlock("off")
        let duplicate = FakeBlock("a")

        runtime.register(a)
        runtime.register(off, enabled: false)
        runtime.register(duplicate)

        #expect(a.activations == 1 && a.context != nil)
        #expect(off.activations == 0)
        #expect(duplicate.activations == 0)
        #expect(runtime.blocks.map { $0.id } == ["a", "off"])
        #expect(runtime.isEnabled("a") && !runtime.isEnabled("off"))
    }

    // Rule 2
    @Test func disablingRemovesSubscriptionsAndPresentationThenDeactivates() {
        let runtime = NotchRuntime()
        let a = FakeBlock("a")
        var received = 0
        var ownerAtDeactivate: BlockID? = "unset"
        a.onActivate = { context in
            context.subscribe(to: Ping.self) { _ in received += 1 }
        }
        a.onDeactivate = { ownerAtDeactivate = runtime.state.owner }
        runtime.register(a)
        a.context?.present(peekPresentation())
        #expect(runtime.state.owner == "a")

        runtime.setEnabled("a", false)
        runtime.publish(Ping(n: 1))
        #expect(a.deactivations == 1)
        #expect(ownerAtDeactivate == nil)
        #expect(received == 0)
        #expect(!runtime.isEnabled("a"))

        runtime.setEnabled("a", false)
        #expect(a.deactivations == 1)

        runtime.setEnabled("a", true)
        runtime.setEnabled("a", true)
        #expect(a.activations == 2)
        runtime.publish(Ping(n: 2))
        #expect(received == 1)
    }

    // Rule 3
    @Test func publishDeliversByExactTypeInRegistrationOrder() {
        let runtime = NotchRuntime()
        var log: [String] = []
        for name in ["first", "second", "third"] {
            let block = FakeBlock(BlockID(rawValue: name))
            block.onActivate = { context in
                context.subscribe(to: Ping.self) { log.append("\(name) ping \($0.n)") }
                context.subscribe(to: Pong.self) { _ in log.append("\(name) pong") }
            }
            runtime.register(block)
        }

        runtime.publish(Ping(n: 7))

        #expect(log == ["first ping 7", "second ping 7", "third ping 7"])
    }

    // Rule 3, re-entrancy
    @Test func handlersMaySubscribePresentAndRegisterDuringDelivery() {
        let runtime = NotchRuntime()
        var calls = 0
        let a = FakeBlock("a")
        a.onActivate = { context in
            context.subscribe(to: Ping.self) { _ in
                calls += 1
                context.subscribe(to: Ping.self) { _ in calls += 1 }
                context.present(peekPresentation())
                runtime.register(FakeBlock("late"))
            }
        }
        runtime.register(a)

        runtime.publish(Ping(n: 1))

        #expect(calls == 1)
        #expect(runtime.state.owner == "a")
        #expect(runtime.blocks.count == 2)
    }

    // Rule 4
    @Test func contextIsInertAfterDeactivation() {
        let runtime = NotchRuntime()
        let a = FakeBlock("a")
        var received = 0
        runtime.register(a)
        let stale = a.context
        runtime.setEnabled("a", false)

        stale?.subscribe(to: Ping.self) { _ in received += 1 }
        stale?.present(peekPresentation())
        runtime.setEnabled("a", true)
        runtime.publish(Ping(n: 1))

        #expect(received == 0)
        #expect(runtime.state.owner == nil)
        #expect(stale?.ownsNotch == false)
    }

    // Rule 10, end to end through the runtime's timer
    @Test func durationTimesOutOnTheInjectedClock() async {
        let clock = ManualClock()
        let runtime = NotchRuntime(clock: clock)
        let a = FakeBlock("a")
        runtime.register(a)
        a.context?.present(peekPresentation(duration: .seconds(5)))

        clock.advance(by: .seconds(4))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(runtime.state.owner == "a")

        clock.advance(by: .seconds(1))
        await waitUntil { runtime.state.owner == nil }
        #expect(runtime.state.owner == nil)
    }

    // Rule 12
    @Test func hoverUpdatesLevelBeforePublishingAndIgnoresRepeats() {
        let runtime = NotchRuntime()
        let a = FakeBlock("a")
        var seen: [(Bool, NotchLevel?)] = []
        a.onActivate = { context in
            context.subscribe(to: PointerHoverChanged.self) { seen.append(($0.isInside, runtime.state.level)) }
        }
        runtime.register(a)
        a.context?.present(Presentation(peek: content(), expanded: content()))

        runtime.pointerHoverChanged(isInside: true)
        runtime.pointerHoverChanged(isInside: true)
        runtime.pointerHoverChanged(isInside: false)
        runtime.pointerHoverChanged(isInside: false)

        #expect(seen.count == 2)
        #expect(seen.first?.0 == true && seen.first?.1 == .expanded)
        #expect(seen.last?.0 == false && seen.last?.1 == .peek)
    }

    // Rule 13
    @Test func sendGoesToTheOwnerOnlyWithAcceptedDropItems() {
        let runtime = NotchRuntime()
        let owner = FakeBlock("owner")
        let other = FakeBlock("other")
        runtime.register(owner)
        runtime.register(other)

        runtime.send(.click)
        #expect(owner.inputs.isEmpty && other.inputs.isEmpty)

        other.context?.present(peekPresentation(.ambient))
        owner.context?.present(peekPresentation(.standard, accepts: [.file]))
        let file = DroppedItem.file(URL(filePath: "/tmp/a.txt"))

        runtime.send(.click)
        runtime.send(.drop([.text("hi"), file]))
        runtime.send(.drop([.text("only text")]))

        #expect(other.inputs.isEmpty)
        #expect(owner.inputs.count == 2)
        guard owner.inputs.count == 2 else { return }
        guard case .click = owner.inputs[0] else { Issue.record("expected click"); return }
        guard case let .drop(items) = owner.inputs[1] else { Issue.record("expected drop"); return }
        #expect(items == [file])
    }

    // Rule 14
    @Test func ownsNotchIsTrueOnlyForTheOwner() {
        let runtime = NotchRuntime()
        let a = FakeBlock("a")
        let b = FakeBlock("b")
        runtime.register(a)
        runtime.register(b)
        #expect(a.context?.ownsNotch == false)

        a.context?.present(peekPresentation(.standard))
        b.context?.present(peekPresentation(.ambient))
        #expect(a.context?.ownsNotch == true)
        #expect(b.context?.ownsNotch == false)

        a.context?.dismiss()
        #expect(a.context?.ownsNotch == false)
        #expect(b.context?.ownsNotch == true)
    }

    // Rule 15
    @Test func stateIsWrittenOnlyWhenOwnerLevelOrPresentationChanges() {
        let runtime = NotchRuntime()
        let a = FakeBlock("a")
        let b = FakeBlock("b")
        runtime.register(a)
        runtime.register(b)
        a.context?.present(peekPresentation(.standard))

        let unchanged = observeState(of: runtime)
        runtime.pointerHoverChanged(isInside: true) // peek-only: level stays .peek
        b.context?.present(peekPresentation(.ambient)) // waits behind a
        b.context?.dismiss()
        a.context?.present(Presentation()) // ignored
        #expect(!unchanged.fired)

        let changed = observeState(of: runtime)
        a.context?.present(peekPresentation(.standard))
        #expect(changed.fired)
    }

    private func observeState(of runtime: NotchRuntime) -> ChangeFlag {
        let flag = ChangeFlag()
        withObservationTracking {
            _ = runtime.state
        } onChange: {
            flag.set()
        }
        return flag
    }
}

final class ChangeFlag: Sendable {
    private let value = Mutex(false)
    var fired: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
