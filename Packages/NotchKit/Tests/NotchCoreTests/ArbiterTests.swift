import Testing
@testable import NotchCore

@MainActor
struct ArbiterTests {
    // Rule 5
    @Test func presentReplacesTheBlocksEarlierPresentation() {
        var arbiter = Arbiter()
        let first = peekPresentation(.interactive)
        let second = peekPresentation(.ambient)
        arbiter.present(first, for: "a", at: .zero)
        arbiter.present(peekPresentation(.standard), for: "b", at: .zero)
        arbiter.present(second, for: "a", at: .zero)

        // a's interactive one is gone, so b (standard) beats a (ambient).
        #expect(arbiter.state.owner == "b")
        arbiter.dismiss("b", at: .zero)
        #expect(arbiter.state.presentation?.id == second.id)
    }

    // Rule 6
    @Test func presentationWithoutContentIsIgnored() {
        var arbiter = Arbiter()
        let shown = peekPresentation()
        arbiter.present(shown, for: "a", at: .zero)

        let accepted = arbiter.present(Presentation(priority: .interactive), for: "a", at: .zero)

        #expect(!accepted)
        #expect(arbiter.state.presentation?.id == shown.id)
        let acceptedEmpty = arbiter.present(Presentation(), for: "b", at: .zero)
    #expect(!acceptedEmpty)
        #expect(arbiter.state.owner == "a")
    }

    // Rule 7
    @Test func highestPriorityOwns() {
        var arbiter = Arbiter()
        arbiter.setRank(["a", "b", "c"], at: .zero)
        arbiter.present(peekPresentation(.ambient), for: "a", at: .zero)
        arbiter.present(peekPresentation(.standard), for: "b", at: .zero)
        arbiter.present(peekPresentation(.ambient), for: "c", at: .zero)
        #expect(arbiter.state.owner == "b")
    }

    // Rule 7, ties
    @Test func equalPriorityGoesToHigherRankNotMostRecent() {
        var arbiter = Arbiter()
        arbiter.setRank(["a", "b"], at: .zero)
        arbiter.present(peekPresentation(.standard), for: "a", at: .zero)
        arbiter.present(peekPresentation(.standard), for: "b", at: .seconds(1))
        #expect(arbiter.state.owner == "a")

        arbiter.dismiss("a", at: .seconds(2))
        #expect(arbiter.state.owner == "b")
        arbiter.present(peekPresentation(.standard), for: "a", at: .seconds(3))
        #expect(arbiter.state.owner == "a")
    }

    // Guard
    @Test func interactiveCountsOnlyDuringInteraction() {
        var arbiter = Arbiter()
        arbiter.setRank(["a", "b"], at: .zero)
        arbiter.present(peekPresentation(.standard), for: "a", at: .zero)
        arbiter.present(peekPresentation(.interactive), for: "b", at: .zero)
        #expect(arbiter.state.owner == "a")

        // During a drag it is interactive again.
        arbiter.setDragActive(true, at: .seconds(1))
        #expect(arbiter.state.owner == "b")
    }

    // Guard, window after a drag
    @Test func interactiveHoldsForTwentySecondsAfterDragEnds() {
        #expect(Arbiter.interactionWindow == .seconds(20))
        var arbiter = Arbiter()
        arbiter.setRank(["a", "b"], at: .zero)
        arbiter.setDragActive(true, at: .zero)
        arbiter.present(peekPresentation(.interactive), for: "b", at: .zero)
        arbiter.present(peekPresentation(.standard), for: "a", at: .seconds(1))
        #expect(arbiter.state.owner == "b")

        arbiter.setDragActive(false, at: .seconds(10))
        #expect(arbiter.nextDeadline == .seconds(30))
        arbiter.advance(to: .seconds(29))
        #expect(arbiter.state.owner == "b")
        arbiter.advance(to: .seconds(31))
        #expect(arbiter.state.owner == "a")
        #expect(arbiter.nextDeadline == nil)
    }

    // Guard, pointer on the owner
    @Test func interactiveHoldsWhilePointerIsOnTheOwner() {
        var arbiter = Arbiter()
        arbiter.setRank(["a", "b"], at: .zero)
        arbiter.present(peekPresentation(.ambient), for: "b", at: .zero)
        arbiter.setPointerInside(true, at: .seconds(1))
        // Browsing: b turns interactive while the pointer is on it.
        arbiter.present(peekPresentation(.interactive), for: "b", at: .seconds(1))
        arbiter.present(peekPresentation(.standard), for: "a", at: .seconds(2))
        #expect(arbiter.state.owner == "b")
        #expect(arbiter.nextDeadline == nil)

        arbiter.advance(to: .seconds(100))
        #expect(arbiter.state.owner == "b")

        arbiter.setPointerInside(false, at: .seconds(100))
        #expect(arbiter.state.owner == "b")
        #expect(arbiter.nextDeadline == .seconds(120))
        arbiter.advance(to: .seconds(119))
        #expect(arbiter.state.owner == "b")
        arbiter.advance(to: .seconds(120))
        #expect(arbiter.state.owner == "a")
    }

    // Guard, the pointer counts for the owner only
    @Test func pointerOnTheNotchDoesNotMakeAWaitingBlockInteractive() {
        var arbiter = Arbiter()
        arbiter.setRank(["a", "b"], at: .zero)
        arbiter.present(peekPresentation(.standard), for: "a", at: .zero)
        arbiter.setPointerInside(true, at: .seconds(1))
        arbiter.present(peekPresentation(.interactive), for: "b", at: .seconds(2))
        #expect(arbiter.state.owner == "a")
    }

    // Notch time rule (D13): an endless view nobody acts on
    @Test func anEndlessInteractiveViewRanksLowestWhenNobodyActsOnIt() {
        var arbiter = Arbiter()
        // The endless view's block is first in the rank: the rank does not save it.
        arbiter.setRank(["shelf", "other"], at: .zero)
        arbiter.setDragActive(true, at: .zero)
        arbiter.present(peekPresentation(.interactive), for: "shelf", at: .zero)
        arbiter.setDragActive(false, at: .seconds(1))
        arbiter.present(peekPresentation(.standard, duration: .seconds(5)), for: "other", at: .seconds(2))
        #expect(arbiter.state.owner == "shelf", "inside the window it still wins")

        arbiter.advance(to: .seconds(21))
        #expect(arbiter.state.owner == "other")
        #expect(arbiter.nextDeadline == .seconds(26))
        arbiter.advance(to: .seconds(26))
        #expect(arbiter.state.owner == "shelf", "it comes back when the timed view ends")
    }

    // Notch time rule (D13): inside the window nothing changes
    @Test func anInteractiveViewStillWinsWhileItsBlockIsInteracting() {
        var arbiter = Arbiter()
        arbiter.setRank(["other", "shelf"], at: .zero)
        arbiter.present(peekPresentation(.interactive), for: "shelf", at: .zero)
        arbiter.setPointerInside(true, at: .seconds(1))
        arbiter.present(peekPresentation(.standard, duration: .seconds(5)), for: "other", at: .seconds(2))
        #expect(arbiter.state.owner == "shelf")

        arbiter.setPointerInside(false, at: .seconds(5))
        arbiter.advance(to: .seconds(24))
        #expect(arbiter.state.owner == "shelf")
        arbiter.advance(to: .seconds(25))
        #expect(arbiter.state.owner == "other")
    }

    // Notch time rule (D13): a timed top-priority view falls to `standard`
    @Test func aTimedInteractiveViewFallsToStandardAsBefore() {
        var arbiter = Arbiter()
        // `base` is first in the rank, so it would win a tie at `ambient`.
        arbiter.setRank(["base", "top"], at: .zero)
        arbiter.present(peekPresentation(.ambient), for: "base", at: .zero)
        arbiter.present(peekPresentation(.interactive, duration: .seconds(10)), for: "top", at: .zero)
        #expect(arbiter.state.owner == "top")

        // At `standard` it ties with another standard view, and the rank decides.
        arbiter.setRank(["result", "top", "base"], at: .seconds(1))
        arbiter.present(peekPresentation(.standard, duration: .seconds(5)), for: "result", at: .seconds(1))
        #expect(arbiter.state.owner == "result")
    }

    // Rank changes
    @Test func setRankChangesTheOwnerAtOnce() {
        var arbiter = Arbiter()
        arbiter.setRank(["a", "b"], at: .zero)
        arbiter.present(peekPresentation(.standard), for: "a", at: .zero)
        arbiter.present(peekPresentation(.standard), for: "b", at: .zero)
        #expect(arbiter.state.owner == "a")

        arbiter.setRank(["b", "a"], at: .seconds(1))
        #expect(arbiter.state.owner == "b")
    }

    // Rule 8
    @Test func higherPriorityPreemptsAndLowerReturnsWhenItEnds() {
        var arbiter = Arbiter()
        let low = peekPresentation(.ambient)
        arbiter.present(low, for: "a", at: .zero)
        arbiter.present(peekPresentation(.interactive), for: "b", at: .seconds(1))
        #expect(arbiter.state.owner == "b")

        arbiter.dismiss("b", at: .seconds(2))
        #expect(arbiter.state.owner == "a")
        #expect(arbiter.state.presentation?.id == low.id)
    }

    // Rule 9
    @Test func ownerLevelFollowsOpensAtHoverAndAvailableContent() {
        var arbiter = Arbiter()

        arbiter.present(Presentation(peek: content(), expanded: content(), opensAt: .expanded), for: "a", at: .zero)
        #expect(arbiter.state.level == .expanded)

        arbiter.present(Presentation(peek: content(), expanded: content(), opensAt: .peek), for: "a", at: .zero)
        #expect(arbiter.state.level == .peek)
        arbiter.setPointerInside(true, at: .zero)
        #expect(arbiter.state.level == .expanded)
        arbiter.setPointerInside(false, at: .zero)
        #expect(arbiter.state.level == .peek)

        // Only expanded content: shown expanded even though it opens at peek.
        arbiter.present(Presentation(expanded: content(), opensAt: .peek), for: "a", at: .zero)
        #expect(arbiter.state.level == .expanded)

        // Only peek content: shown at peek even when it opens expanded and is hovered.
        arbiter.present(Presentation(peek: content(), opensAt: .expanded), for: "a", at: .zero)
        arbiter.setPointerInside(true, at: .zero)
        #expect(arbiter.state.level == .peek)
    }

    // Rule 10
    @Test func durationRunsOnlyWhileOwnerAndPointerOutside() {
        var arbiter = Arbiter()
        arbiter.present(peekPresentation(.ambient), for: "base", at: .zero)
        arbiter.present(peekPresentation(.standard, duration: .seconds(10)), for: "timed", at: .zero)
        #expect(arbiter.nextDeadline == .seconds(10))

        // Hover at 4s pauses with 6s left; leaving at 20s resumes from 6s.
        arbiter.setPointerInside(true, at: .seconds(4))
        #expect(arbiter.nextDeadline == nil)
        arbiter.advance(to: .seconds(15))
        #expect(arbiter.state.owner == "timed")
        arbiter.setPointerInside(false, at: .seconds(20))
        #expect(arbiter.nextDeadline == .seconds(26))

        // Pre-empted at 22s with 4s left: a waiting presentation does not count down.
        // `top` is timed: an endless one nobody acts on would rank below `timed`.
        arbiter.present(peekPresentation(.interactive, duration: .seconds(1000)), for: "top", at: .seconds(22))
        #expect(arbiter.state.owner == "top")
        #expect(arbiter.nextDeadline == .seconds(1022))
        arbiter.advance(to: .seconds(100))
        arbiter.dismiss("top", at: .seconds(100))
        #expect(arbiter.state.owner == "timed")
        #expect(arbiter.nextDeadline == .seconds(104))

        arbiter.advance(to: .seconds(103))
        #expect(arbiter.state.owner == "timed")
        arbiter.advance(to: .seconds(104))
        #expect(arbiter.state.owner == "base")
        #expect(arbiter.nextDeadline == nil)
    }

    // Rule 10, last presentation
    @Test func expiredDurationWithNothingWaitingGoesIdle() {
        var arbiter = Arbiter()
        arbiter.present(peekPresentation(duration: .seconds(2)), for: "a", at: .seconds(1))
        arbiter.advance(to: .seconds(3))
        #expect(arbiter.state.owner == nil)
    }

    // Rule 11
    @Test func dismissRemovesTheBlocksPresentationAndIdlesWhenNoneLeft() {
        var arbiter = Arbiter()
        arbiter.present(peekPresentation(), for: "a", at: .zero)
        arbiter.dismiss("b", at: .zero)
        #expect(arbiter.state.owner == "a")

        arbiter.dismiss("a", at: .zero)
        #expect(arbiter.state.owner == nil)
        #expect(arbiter.nextDeadline == nil)
    }
}

@MainActor
@Test func aWingAloneIsShownAtThePeekLevel() {
    let runtime = NotchRuntime()
    let block = FakeBlock("a")
    runtime.register(block)
    block.context?.present(Presentation(wing: content(), expanded: content()))
    #expect(runtime.state.owner == "a")
    #expect(runtime.state.level == .peek)
    runtime.pointerHoverChanged(isInside: true)
    #expect(runtime.state.level == .expanded)
}
