import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
@Suite(.serialized)
struct BlockStoreTests {
    private func store(
        _ runtime: NotchRuntime, blocksRoot: URL? = nil, dataRoot: URL? = nil,
        isRegistered: @escaping @MainActor (BlockID) -> Bool = { _ in false }
    ) -> BlockStore {
        let store = BlockStore(
            owner: { runtime.state.owner },
            blocksRoot: blocksRoot ?? FileManager.default.temporaryDirectory.appending(path: "mantel-blocks-\(UUID().uuidString)"),
            dataRoot: dataRoot ?? FileManager.default.temporaryDirectory.appending(path: "mantel-data-\(UUID().uuidString)"),
            defaults: testDefaults(),
            isRegistered: isRegistered
        )
        // The fixture packages are not signed; installed ones count as signed.
        store.signatures = FakeSignatures()
        return store
    }

    /// `<root>/<name>.mantelblock`: a bundle with a copy of the fixture
    /// executable under the manifest `id`. A copy, not a link: the validator
    /// refuses an executable that leads outside its package, and the
    /// sandbox reads only the package.
    @discardableResult
    private func fixturePackage(id: String = "fixture", name: String = "Fixture", in root: URL? = nil) throws -> URL {
        let root = root ?? FileManager.default.temporaryDirectory.appending(path: "mantel-fixture-\(UUID().uuidString)")
        let folder = root.appending(path: "\(name).mantelblock")
        var manifest = Fixture.manifest
        manifest.id = id
        manifest.name = name
        let executable = try #require(Fixture.executable, "\(Fixture.FixtureMissing())")
        try writeBundle(at: folder, manifest: manifest, executable: executable)
        return folder
    }

    /// The app at launch: the installed blocks by id, each waiting for the
    /// owner's review without an approval, then the development block.
    @Test func installedBlocksComeBeforeTheDevelopmentBlock() throws {
        let blocks = FileManager.default.temporaryDirectory.appending(path: "mantel-blocks-\(UUID().uuidString)")
        try fixturePackage(id: "beta", name: "Beta", in: blocks)
        try fixturePackage(id: "alpha", name: "Alpha", in: blocks)
        // Not a package: ignored.
        try FileManager.default.createDirectory(at: blocks.appending(path: "Notes"), withIntermediateDirectories: true)
        let development = try fixturePackage()

        let standIns = store(NotchRuntime(), blocksRoot: blocks).standIns(developmentPath: development.path)

        #expect(standIns.map(\.id) == ["alpha", "beta", "fixture"])
        #expect(standIns.prefix(2).allSatisfy { $0 is PendingBlock })
        #expect(standIns.last?.info.source == .development(path: development.path))
    }

    /// The app ships with no blocks: with nothing installed and no
    /// development path, there is nothing to register.
    @Test func noInstalledBlocksAndNoDevelopmentPathGiveNone() throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "mantel-blocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(store(NotchRuntime(), blocksRoot: empty).standIns(developmentPath: nil).isEmpty)
        #expect(store(NotchRuntime(), blocksRoot: URL(fileURLWithPath: "/no/such/Blocks")).standIns(developmentPath: nil).isEmpty)
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
        #expect(store.standIns(developmentPath: "/no/such/Block.mantelblock").isEmpty)

        // A manifest that does not decode.
        let broken = FileManager.default.temporaryDirectory.appending(path: "mantel-broken-\(UUID().uuidString).mantelblock")
        try writeBrokenManifest(in: broken, "{\"name\": \"No id\"}")
        #expect(store.standIns(developmentPath: broken.path).isEmpty)

        // A valid manifest whose executable is missing.
        let empty = FileManager.default.temporaryDirectory.appending(path: "mantel-empty-\(UUID().uuidString).mantelblock")
        try writeBundle(at: empty, manifest: Fixture.manifest, writeExecutable: false)
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
        let blocks = FileManager.default.temporaryDirectory.appending(path: "mantel-blocks-\(UUID().uuidString)")
        try fixturePackage(id: "fixture", name: "Fixture", in: blocks)
        // The same id again, run as the development block: the installed one wins.
        let development = try fixturePackage()

        let standIns = store(NotchRuntime(), blocksRoot: blocks).standIns(developmentPath: development.path)

        #expect(standIns.map(\.id) == ["fixture"])
        let installed = try #require(standIns.first as? PendingBlock)
        #expect(installed.info.source == .installed(from: installed.packageURL.path))
    }

    @Test func idAlreadyRegisteredIsSkipped() throws {
        let development = try fixturePackage()
        let standIns = store(NotchRuntime(), isRegistered: { $0 == "fixture" }).standIns(developmentPath: development.path)
        #expect(standIns.isEmpty)
    }

    @Test func aPackageUnderAnyFolderNameIsFound() throws {
        let blocks = FileManager.default.temporaryDirectory.appending(path: "mantel-blocks-\(UUID().uuidString)")
        // Named after the block's name, as the packaging script names it.
        try fixturePackage(id: "weather-peek", name: "Weather Peek", in: blocks)
        // A second package with the same id.
        try fixturePackage(id: "weather-peek", name: "Weather Peek Copy", in: blocks)

        let store = store(NotchRuntime(), blocksRoot: blocks)
        let standIns = store.standIns(developmentPath: nil)

        #expect(standIns.count == 2)
        let pending = try #require(standIns.first as? PendingBlock)
        #expect(pending.id == "weather-peek")
        #expect(pending.review == .new)
        #expect(pending.packageURL.lastPathComponent == "Weather Peek.mantelblock")
        let duplicate = try #require(standIns.last as? RefusedBlock)
        #expect(duplicate.packageURL.lastPathComponent == "Weather Peek Copy.mantelblock")
        guard case let .turnedOff(reason) = duplicate.health else {
            Issue.record("the second package is listed turned off")
            return
        }
        #expect(reason.contains("\"weather-peek\""))
        #expect(store.canRemove(duplicate.id), "the extra copy can be removed")
    }

    // MARK: Refused at launch

    @Test func refusedInstalledPackageIsListedTurnedOff() throws {
        let blocks = FileManager.default.temporaryDirectory.appending(path: "mantel-blocks-\(UUID().uuidString)")
        // A contract this app does not run.
        let old = blocks.appending(path: "old.mantelblock")
        var manifest = Fixture.manifest
        manifest.id = "old"
        manifest.name = "Old Block"
        manifest.contract = 99
        try writeBundle(at: old, manifest: manifest)
        // A manifest that does not decode: titled with its id.
        let broken = blocks.appending(path: "broken.mantelblock")
        try writeBrokenManifest(in: broken, "{}")

        let store = store(NotchRuntime(), blocksRoot: blocks)
        let standIns = store.standIns(developmentPath: nil)

        #expect(standIns.map(\.id) == ["broken", "old"])
        let refused = try #require(standIns.last as? RefusedBlock)
        #expect(refused.title == "Old Block")
        #expect(refused.packageURL.lastPathComponent == "old.mantelblock")
        #expect(refused.info.source == .installed(from: refused.packageURL.path))
        let reason = BlockInstallError.unsupportedContract(found: 99, supported: Contract.supported).errorDescription
        #expect(refused.health == .turnedOff(reason: try #require(reason)))
        #expect(standIns.first?.title == "broken")
        #expect(store.canRemove("old"))
        #expect(!store.canTurnOn("old"))
    }

    /// A bundle whose `Contents/Resources/manifest.json` is `json`.
    private func writeBrokenManifest(in folder: URL, _ json: String) throws {
        let resources = folder.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: resources.appending(path: "manifest.json"))
    }
}
