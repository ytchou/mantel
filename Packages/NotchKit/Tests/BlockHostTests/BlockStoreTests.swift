import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
@Suite(.serialized)
struct BlockStoreTests {
    private func store(
        _ runtime: NotchRuntime, bundledRoot: URL? = nil, blocksRoot: URL? = nil,
        isRegistered: @escaping @MainActor (BlockID) -> Bool = { _ in false }
    ) -> BlockStore {
        BlockStore(
            owner: { runtime.state.owner },
            blocksRoot: blocksRoot ?? FileManager.default.temporaryDirectory.appending(path: "topnotch-blocks-\(UUID().uuidString)"),
            dataRoot: FileManager.default.temporaryDirectory.appending(path: "topnotch-data-\(UUID().uuidString)"),
            bundledRoot: bundledRoot,
            defaults: testDefaults(),
            isRegistered: isRegistered
        )
    }

    /// `<root>/<name>.topblock`: a copy of the fixture executable under the
    /// manifest `id`. A copy, not a link: the validator refuses an executable
    /// that leads outside its package.
    @discardableResult
    private func fixturePackage(id: String = "fixture", name: String = "Fixture", in root: URL? = nil) throws -> URL {
        let root = root ?? FileManager.default.temporaryDirectory.appending(path: "topnotch-fixture-\(UUID().uuidString)")
        let folder = root.appending(path: "\(name).topblock")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = Fixture.manifest
        manifest.id = id
        manifest.name = name
        try Framing.encoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        let executable = try #require(Fixture.executable, "\(Fixture.FixtureMissing())")
        try FileManager.default.copyItem(at: executable, to: folder.appending(path: manifest.executable))
        return folder
    }

    private func bundledPackage(id: String, name: String, in root: URL) throws {
        try fixturePackage(id: id, name: name, in: root)
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
        let development = try fixturePackage()

        let standIns = store(NotchRuntime(), bundledRoot: root).standIns(developmentPath: development.path)

        #expect(standIns.map(\.id) == ["alpha", "nowplaying", "fixture"])
        #expect(standIns.map(\.info.source) == [.bundled, .bundled, .development(path: development.path)])
        #expect((standIns.first as? RemoteBlock)?.packageURL.lastPathComponent == "Alpha.topblock")
    }

    @Test func missingBundledFolderGivesNone() {
        let store = store(NotchRuntime(), bundledRoot: URL(fileURLWithPath: "/no/such/Blocks"))
        #expect(store.standIns(developmentPath: nil).isEmpty)
    }

    @Test func developmentPathGivesOneStandIn() throws {
        let package = try fixturePackage()
        let standIns = store(NotchRuntime()).standIns(developmentPath: package.path)

        #expect(standIns.count == 1)
        let block = try #require(standIns.first as? RemoteBlock)
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
        let package = try fixturePackage()
        let runtime = NotchRuntime()
        let store = store(runtime)
        let blocks = store.standIns(developmentPath: package.path)
        for block in blocks { runtime.register(block) }

        let block = try #require(blocks.first as? RemoteBlock)
        await waitUntil { block.isWelcomed }
        #expect(block.isWelcomed, "the fixture said hello")
        let pid = try #require(block.processID)
        #expect(processExists(pid))

        store.stopAll()

        #expect(!processExists(pid))
        #expect(block.processID == nil)
    }

    // MARK: Ids are unique

    @Test func laterDuplicateIdIsSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "topnotch-bundled-\(UUID().uuidString)/Blocks")
        try bundledPackage(id: "fixture", name: "Fixture", in: root)
        // The same id again, run as the development block: the bundled one wins.
        let development = try fixturePackage()

        let standIns = store(NotchRuntime(), bundledRoot: root).standIns(developmentPath: development.path)

        #expect(standIns.map(\.id) == ["fixture"])
        #expect(standIns.map(\.info.source) == [.bundled])
    }

    @Test func idAlreadyRegisteredIsSkipped() throws {
        let development = try fixturePackage()
        let standIns = store(NotchRuntime(), isRegistered: { $0 == "fixture" }).standIns(developmentPath: development.path)
        #expect(standIns.isEmpty)
    }

    @Test func installedFolderMustBeNamedAfterItsId() throws {
        let blocks = FileManager.default.temporaryDirectory.appending(path: "topnotch-blocks-\(UUID().uuidString)")
        // Named after another id: skipped.
        try fixturePackage(id: "alpha", name: "beta", in: blocks)
        // Not a valid id, or a reserved one: skipped.
        try fixturePackage(id: "fixture", name: "Not An Id", in: blocks)
        try fixturePackage(id: "shelf", name: "shelf", in: blocks)
        // Named after its id: kept.
        try fixturePackage(id: "gamma", name: "gamma", in: blocks)

        let standIns = store(NotchRuntime(), blocksRoot: blocks).standIns(developmentPath: nil)

        #expect(standIns.map(\.id) == ["gamma"])
    }

    // MARK: Refused at launch

    @Test func refusedInstalledPackageIsListedTurnedOff() throws {
        let blocks = FileManager.default.temporaryDirectory.appending(path: "topnotch-blocks-\(UUID().uuidString)")
        // A contract this app does not run.
        let old = blocks.appending(path: "old.topblock")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        var manifest = Fixture.manifest
        manifest.id = "old"
        manifest.name = "Old Block"
        manifest.contract = 99
        try Framing.encoder().encode(manifest).write(to: old.appending(path: "manifest.json"))
        // A manifest that does not decode: titled with its id.
        let broken = blocks.appending(path: "broken.topblock")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: broken.appending(path: "manifest.json"))

        let store = store(NotchRuntime(), blocksRoot: blocks)
        let standIns = store.standIns(developmentPath: nil)

        #expect(standIns.map(\.id) == ["broken", "old"])
        let refused = try #require(standIns.last as? RefusedBlock)
        #expect(refused.title == "Old Block")
        #expect(refused.packageURL.lastPathComponent == "old.topblock")
        #expect(refused.info.source == .installed(from: refused.packageURL.path))
        let reason = BlockInstallError.unsupportedContract(found: 99, supported: Contract.supported).errorDescription
        #expect(refused.health == .turnedOff(reason: try #require(reason)))
        #expect(standIns.first?.title == "broken")
        #expect(store.canRemove("old"))
        #expect(!store.canTurnOn("old"))
    }
}
