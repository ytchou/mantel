import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
@Suite(.serialized)
struct BlockStoreTests {
    private func store(_ runtime: NotchRuntime, bundledRoot: URL? = nil) -> BlockStore {
        BlockStore(
            owner: { runtime.state.owner },
            blocksRoot: FileManager.default.temporaryDirectory.appending(path: "topnotch-blocks-\(UUID().uuidString)"),
            dataRoot: FileManager.default.temporaryDirectory.appending(path: "topnotch-data-\(UUID().uuidString)"),
            bundledRoot: bundledRoot
        )
    }

    /// `<root>/<name>.topblock`: the fixture executable under the manifest `id`.
    private func bundledPackage(id: String, name: String, in root: URL) throws {
        let folder = root.appending(path: "\(name).topblock")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = Fixture.manifest
        manifest.id = id
        manifest.name = name
        try Framing.encoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        let executable = try #require(Fixture.executable, "\(Fixture.FixtureMissing())")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: manifest.executable), withDestinationURL: executable)
    }

    @Test func bundledBlocksComeFirstWithSourceBundled() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "topnotch-bundled-\(UUID().uuidString)/Blocks")
        // A reserved id is allowed for a bundled package: now-playing ships this way.
        try bundledPackage(id: "nowplaying", name: "NowPlaying", in: root)
        try bundledPackage(id: "alpha", name: "Alpha", in: root)
        // Not a package: ignored.
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        // A package that does not validate: logged and left out.
        let broken = root.appending(path: "Broken.topblock")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: broken.appending(path: "manifest.json"))
        let development = try Fixture.package()

        let standIns = store(NotchRuntime(), bundledRoot: root).standIns(developmentPath: development.path)

        #expect(standIns.map(\.id) == ["alpha", "nowplaying", "fixture"])
        #expect(standIns.map(\.info.source) == [.bundled, .bundled, .development(path: development.path)])
        #expect(standIns.first?.packageURL.lastPathComponent == "Alpha.topblock")
    }

    @Test func missingBundledFolderGivesNone() {
        let store = store(NotchRuntime(), bundledRoot: URL(fileURLWithPath: "/no/such/Blocks"))
        #expect(store.standIns(developmentPath: nil).isEmpty)
    }

    @Test func developmentPathGivesOneStandIn() throws {
        let package = try Fixture.package()
        let standIns = store(NotchRuntime()).standIns(developmentPath: package.path)

        #expect(standIns.count == 1)
        let block = try #require(standIns.first)
        #expect(block.id == "fixture")
        #expect(block.title == "Fixture")
        #expect(block.info.source == .development(path: package.path))
        #expect(block.info.version == "1.0.0")
    }

    @Test func missingOrInvalidDevelopmentPathGivesNoneAndLogs() throws {
        let store = store(NotchRuntime())
        #expect(store.standIns(developmentPath: nil).isEmpty)
        #expect(store.standIns(developmentPath: "/no/such/Block.topblock").isEmpty)

        // A manifest that does not decode.
        let broken = FileManager.default.temporaryDirectory.appending(path: "topnotch-broken-\(UUID().uuidString).topblock")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{\"name\": \"No id\"}".utf8).write(to: broken.appending(path: "manifest.json"))
        #expect(store.standIns(developmentPath: broken.path).isEmpty)

        // A valid manifest whose executable is missing.
        let empty = FileManager.default.temporaryDirectory.appending(path: "topnotch-empty-\(UUID().uuidString).topblock")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Framing.encoder().encode(Fixture.manifest).write(to: empty.appending(path: "manifest.json"))
        #expect(store.standIns(developmentPath: empty.path).isEmpty)
    }

    @Test func stopAllEndsEveryProcess() async throws {
        let package = try Fixture.package()
        let runtime = NotchRuntime()
        let store = store(runtime)
        let blocks = store.standIns(developmentPath: package.path)
        for block in blocks { runtime.register(block) }

        let block = try #require(blocks.first)
        await waitUntil { block.isWelcomed }
        #expect(block.isWelcomed, "the fixture said hello")
        let pid = try #require(block.processID)
        #expect(processExists(pid))

        store.stopAll()

        #expect(!processExists(pid))
        #expect(block.processID == nil)
    }
}
