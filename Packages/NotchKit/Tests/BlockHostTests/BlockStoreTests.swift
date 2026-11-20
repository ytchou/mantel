import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

@MainActor
@Suite(.serialized)
struct BlockStoreTests {
    private func store(_ runtime: NotchRuntime) -> BlockStore {
        BlockStore(
            owner: { runtime.state.owner },
            dataRoot: FileManager.default.temporaryDirectory.appending(path: "topnotch-data-\(UUID().uuidString)")
        )
    }

    /// `Fixture.package()` with options on its `command` choice, so the
    /// package passes `PackageValidator` (a choice needs options).
    private func validFixturePackage() throws -> URL {
        let package = try Fixture.package()
        var manifest = Fixture.manifest
        manifest.settings = manifest.settings.map { setting in
            var setting = setting
            if setting.type == .choice, setting.options?.isEmpty ?? true {
                setting.options = [.init(value: "none", title: "None")]
            }
            return setting
        }
        try Framing.encoder().encode(manifest).write(to: package.appending(path: "manifest.json"))
        return package
    }

    @Test func developmentPathGivesOneStandIn() throws {
        let package = try validFixturePackage()
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
        let package = try validFixturePackage()
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
