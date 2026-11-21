import Foundation
import NotchCore
import Testing
@testable import EventSources

// MARK: Candidate names

@Test func visibleImageFilesAreCandidates() {
    #expect(ScreenshotCandidate.isCandidateName("Screenshot 2026-11-18 at 10.00.00.png"))
    #expect(ScreenshotCandidate.isCandidateName("shot.PNG"))
    #expect(ScreenshotCandidate.isCandidateName("shot.heic"))
}

@Test func hiddenAndNonImageFilesAreNotCandidates() {
    #expect(!ScreenshotCandidate.isCandidateName(".Screenshot 2026-11-18 at 10.00.00.png"))
    #expect(!ScreenshotCandidate.isCandidateName("notes.txt"))
    #expect(!ScreenshotCandidate.isCandidateName("no-extension"))
    #expect(!ScreenshotCandidate.isCandidateName(""))
}

// MARK: Decision

private let start = Date(timeIntervalSinceReferenceDate: 1_000)

private func facts(
    exists: Bool = true,
    size: Int64 = 100,
    created: Date? = Date(timeIntervalSinceReferenceDate: 1_005),
    screenCapture: Bool? = true,
    renamed: Bool = false
) -> ScreenshotCandidate.Facts {
    .init(exists: exists, size: size, createdAt: created, isScreenCapture: screenCapture, isRenamedByApp: renamed)
}

@Test func aFinishedScreenshotIsPublished() {
    #expect(ScreenshotCandidate.decide(facts(), startedAt: start) == .publish)
}

@Test func anEmptyFileOrMissingAttributeWaits() {
    #expect(ScreenshotCandidate.decide(facts(size: 0), startedAt: start) == .retry)
    #expect(ScreenshotCandidate.decide(facts(screenCapture: nil), startedAt: start) == .retry)
}

@Test func nonScreenshotsOldFilesGoneFilesAndOwnRenamesAreIgnored() {
    #expect(ScreenshotCandidate.decide(facts(screenCapture: false), startedAt: start) == .ignore)
    #expect(ScreenshotCandidate.decide(facts(created: Date(timeIntervalSinceReferenceDate: 900)), startedAt: start) == .ignore)
    #expect(ScreenshotCandidate.decide(facts(exists: false), startedAt: start) == .ignore)
    #expect(ScreenshotCandidate.decide(facts(renamed: true), startedAt: start) == .ignore)
}

@Test func theScreenCaptureFlagIsReadFromABinaryPlist() throws {
    let yes = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
    let no = try PropertyListSerialization.data(fromPropertyList: false, format: .binary, options: 0)
    #expect(ScreenshotCandidate.parseScreenCaptureFlag(yes) == true)
    #expect(ScreenshotCandidate.parseScreenCaptureFlag(no) == false)
    #expect(ScreenshotCandidate.parseScreenCaptureFlag(Data([0x00, 0x01])) == nil)
}

// MARK: Dedupe

@Test func onlyNamesAddedSinceTheLastListingAreReported() {
    var tracker = ScreenshotTracker(startedAt: start, existing: ["old.png"])
    let first = tracker.added(in: ["old.png", "b.png", "a.png"])
    #expect(first == ["a.png", "b.png"])
    let second = tracker.added(in: ["old.png", "b.png", "a.png"])
    #expect(second.isEmpty)
}

@Test func eachNameIsPublishedOnce() {
    var tracker = ScreenshotTracker(startedAt: start)
    let first = tracker.markPublished("a.png")
    let again = tracker.markPublished("a.png")
    #expect(first)
    #expect(!again)
}

@Test func aNameThatLeavesAndComesBackIsReportedButNotRepublished() {
    var tracker = ScreenshotTracker(startedAt: start)
    _ = tracker.added(in: ["a.png"])
    let published = tracker.markPublished("a.png")
    _ = tracker.added(in: ["renamed.png"])
    let back = tracker.added(in: ["a.png"])
    let publishedAgain = tracker.markPublished("a.png")
    #expect(published)
    #expect(back == ["a.png"])
    #expect(!publishedAgain)
}

// MARK: Folder resolution

private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

@Test func aTildeLocationIsExpandedAgainstHome() {
    let url = ScreenshotFolder.resolve(location: "~/Pictures/Shots", home: home) { _ in true }
    #expect(url.path == "/Users/someone/Pictures/Shots")
}

@Test func anAbsoluteLocationIsUsedAsIs() {
    let url = ScreenshotFolder.resolve(location: "/Volumes/Data/Shots\n", home: home) { _ in true }
    #expect(url.path == "/Volumes/Data/Shots")
}

@Test func aMissingEmptyOrNonFolderLocationFallsBackToDesktop() {
    let missing = ScreenshotFolder.resolve(location: nil, home: home) { _ in true }
    let empty = ScreenshotFolder.resolve(location: "  ", home: home) { _ in true }
    let notFolder = ScreenshotFolder.resolve(location: "/nope", home: home) { _ in false }
    #expect(missing.path == "/Users/someone/Desktop")
    #expect(empty.path == "/Users/someone/Desktop")
    #expect(notFolder.path == "/Users/someone/Desktop")
}

/// The watcher reads the one `ScreenshotFolder` in NotchCore, the same one
/// the settings rows ask for access to.
@MainActor
@Test func theWatcherReadsTheSharedScreenshotFolder() throws {
    let watcher = ScreenshotWatcher(runtime: NotchRuntime())
    watcher.start()
    defer { watcher.stop() }
    let scanner = try #require(watcher.scanner)
    #expect(scanner.folder == NotchCore.ScreenshotFolder.current())
}
