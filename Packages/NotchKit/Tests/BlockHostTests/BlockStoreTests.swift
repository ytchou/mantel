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
        let store = BlockStore(
            owner: { runtime.state.owner },
            blocksRoot: blocksRoot ?? FileManager.default.temporaryDirectory.appending(path: "topnotch-blocks-\(UUID().uuidString)"),
            dataRoot: FileManager.default.temporaryDirectory.appending(path: "topnotch-data-\(UUID().uuidString)"),
            bundledRoot: bundledRoot,
            defaults: testDefaults(),
            isRegistered: isRegistered
        )
        // The fixture packages are not signed; installed ones count as signed.
        store.signatures = FakeSignatures()
        return store
    }

    /// `<root>/<name>.topblock`: a bundle with a copy of the fixture
    /// executable under the manifest `id`. A copy, not a link: the validator
    /// refuses an executable that leads outside its package, and the
    /// sandbox reads only the package.
    @discardableResult
    private func fixturePackage(id: String = "fixture", name: String = "Fixture", in root: URL? = nil) throws -> URL {
        let root = root ?? FileManager.default.temporaryDirectory.appending(path: "topnotch-fixture-\(UUID().uuidString)")
        let folder = root.appending(path: "\(name).topblock")
        var manifest = Fixture.manifest
        manifest.id = id
        manifest.name = name
        let executable = try #require(Fixture.executable, "\(Fixture.FixtureMissing())")
        try writeBundle(at: folder, manifest: manifest, executable: executable)
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
        try writeBrokenManifest(in: broken, "{}")
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
        try writeBrokenManifest(in: broken, "{\"name\": \"No id\"}")
        #expect(store.standIns(developmentPath: broken.path).isEmpty)

        // A valid manifest whose executable is missing.
        let empty = FileManager.default.temporaryDirectory.appending(path: "topnotch-empty-\(UUID().uuidString).topblock")
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
        var manifest = Fixture.manifest
        manifest.id = "old"
        manifest.name = "Old Block"
        manifest.contract = 99
        try writeBundle(at: old, manifest: manifest)
        // A manifest that does not decode: titled with its id.
        let broken = blocks.appending(path: "broken.topblock")
        try writeBrokenManifest(in: broken, "{}")

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

    // MARK: Old data folders

    @Test func oldDataFoldersMoveOnce() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "topnotch-support-\(UUID().uuidString)")
        let dataRoot = support.appending(path: "BlockData")
        for folder in ["Shelf", "Rename"] {
            try FileManager.default.createDirectory(at: support.appending(path: folder), withIntermediateDirectories: true)
            try Data(folder.utf8).write(to: support.appending(path: "\(folder)/state"))
        }

        BlockStore.moveOldDataFolders(from: support, to: dataRoot, for: ["shelf", "rename"])

        #expect(try Data(contentsOf: dataRoot.appending(path: "shelf/state")) == Data("Shelf".utf8))
        #expect(try Data(contentsOf: dataRoot.appending(path: "rename/state")) == Data("Rename".utf8))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "Shelf").path))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "Rename").path))

        // The target exists: an old folder that appears again is left alone.
        try FileManager.default.createDirectory(at: support.appending(path: "Shelf"), withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: support.appending(path: "Shelf/state"))
        BlockStore.moveOldDataFolders(from: support, to: dataRoot, for: ["shelf", "rename"])
        #expect(try Data(contentsOf: dataRoot.appending(path: "shelf/state")) == Data("Shelf".utf8))
        #expect(FileManager.default.fileExists(atPath: support.appending(path: "Shelf/state").path))

        // A block still built into the app keeps its folder.
        let other = FileManager.default.temporaryDirectory.appending(path: "topnotch-support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other.appending(path: "Rename"), withIntermediateDirectories: true)
        BlockStore.moveOldDataFolders(from: other, to: other.appending(path: "BlockData"), for: ["shelf"])
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "Rename").path))
        #expect(!FileManager.default.fileExists(atPath: other.appending(path: "BlockData/rename").path))
    }

    /// A bundle whose `Contents/Resources/manifest.json` is `json`.
    private func writeBrokenManifest(in folder: URL, _ json: String) throws {
        let resources = folder.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: resources.appending(path: "manifest.json"))
    }
}
