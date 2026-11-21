import BlockWire
import Foundation
import Testing
@testable import BlockHost
import NotchCore

/// Install, update and remove, in temporary folders with in-memory block
/// processes. The real Application Support folder is never touched.
@MainActor
@Suite(.serialized)
struct InstallTests {
    /// A store over temporary roots, wired to `runtime` the way the app wires it.
    @MainActor
    final class Setup {
        let runtime = NotchRuntime()
        let launcher = FakeLauncher()
        let defaults = testDefaults()
        let root = FileManager.default.temporaryDirectory.appending(path: "topnotch-install-\(UUID().uuidString)")
        var cleared: [BlockID] = []
        /// Every package counts as signed by `FakeSignatures.signer` until a test says otherwise.
        let signatures = FakeSignatures()
        var blocksRoot: URL { root.appending(path: "Blocks") }
        var dataRoot: URL { root.appending(path: "BlockData") }
        lazy var store = makeStore()

        /// - Parameter checksRuntime: false for a second store that only scans
        ///   the folders, so the blocks the first one registered do not count.
        func makeStore(bundledRoot: URL? = nil, checksRuntime: Bool = true) -> BlockStore {
            let store = BlockStore(
                owner: { [runtime] in runtime.state.owner },
                blocksRoot: blocksRoot,
                dataRoot: dataRoot,
                bundledRoot: bundledRoot,
                launcher: launcher.launcher,
                defaults: defaults,
                register: { [runtime] block in runtime.register(block) },
                unregister: { [runtime] id in runtime.unregister(id) },
                clearKeys: { [weak self, defaults] id in
                    self?.cleared.append(id)
                    // As `BlockSettings.clear` does.
                    for key in defaults.dictionaryRepresentation().keys
                    where key.hasPrefix("\(id.rawValue).") || key.hasPrefix("block.\(id.rawValue).") {
                        defaults.removeObject(forKey: key)
                    }
                },
                isRegistered: { [runtime] id in checksRuntime && runtime.blocks.contains { $0.id == id } }
            )
            store.signatures = signatures
            return store
        }

        /// A `<folder>/<Name>.topblock` bundle outside the store, with an executable script.
        func package(
            id: String = "hello", version: String = "0.2", events: [String] = ["pointerHover"],
            contract: Int = Contract.current, folder: String = "hello-block"
        ) throws -> URL {
            let url = root.appending(path: "source-\(UUID().uuidString)").appending(path: folder)
                .appending(path: "Hello.topblock")
            let manifest = Manifest(id: id, name: "Hello", version: version, contract: contract, executable: "HelloBlock",
                                    summary: "Says hello.", trigger: "Pointer hover",
                                    permissions: ["Nothing special"], events: events,
                                    settings: [SettingSpec(key: "loud", type: .toggle, title: "Loud", default: .bool(false))])
            try writeBundle(at: url, manifest: manifest)
            return url
        }

        func installedPackages() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: blocksRoot.path)) ?? []).sorted()
        }

        func block(_ id: BlockID) -> RemoteBlock? {
            runtime.blocks.first { $0.id == id } as? RemoteBlock
        }
    }

    @Test func inspectReturnsSummaryWithoutCopying() throws {
        let setup = Setup()
        let package = try setup.package(events: ["pointerHover", "outputVolume"])

        let summary = try setup.store.inspect(package)

        #expect(summary.id == "hello")
        #expect(summary.name == "Hello")
        #expect(summary.version == "0.2")
        #expect(summary.contract == Contract.current)
        #expect(summary.events == ["Pointer over the notch", "Volume changes"])
        #expect(summary.newEvents.isEmpty)
        #expect(summary.permissions == ["Nothing special"])
        #expect(summary.sourcePath == package.path)
        #expect(summary.installedVersion == nil)
        #expect(setup.installedPackages().isEmpty)
        #expect(setup.runtime.blocks.isEmpty)
    }

    @Test func inspectReturnsTheEntriesOfThePackagesEvents() throws {
        let setup = Setup()
        let order = ["screenshotCaptured", "pointerHover", "nowPlaying"]
        let package = try setup.package(events: order)

        let summary = try setup.store.inspect(package)

        #expect(summary.eventEntries.count == order.count)
        #expect(summary.eventEntries == order.map { EventCatalog.entry(for: WireEvent(rawValue: $0)!) })
        #expect(summary.eventEntries.map(\.name) == summary.events)
    }

    @Test func installCopiesRegistersAndTurnsOn() throws {
        let setup = Setup()
        let package = try setup.package()

        try setup.store.install(package)

        #expect(setup.installedPackages() == ["hello.topblock"])
        let block = try #require(setup.block("hello"))
        #expect(block.packageURL.path == setup.blocksRoot.appending(path: "hello.topblock").path)
        #expect(setup.runtime.isEnabled("hello"))
        #expect(setup.launcher.processes.count == 1, "the block process was started")
        #expect(block.info.source == .installed(from: package.path))
        #expect(setup.store.canRemove("hello"))

        // A new store over the same folder finds it, with the original path.
        let again = setup.makeStore(checksRuntime: false).standIns(developmentPath: nil)
        #expect(again.map(\.id) == ["hello"])
        #expect(again.first?.info.source == .installed(from: package.path))
    }

    @Test func installOfInvalidPackageLeavesNothing() throws {
        let setup = Setup()
        let package = try setup.package(contract: 99)

        #expect(throws: BlockInstallError.unsupportedContract(found: 99, supported: Contract.supported)) {
            try setup.store.install(package)
        }
        let reserved = try setup.package(id: "shelf")
        #expect(throws: BlockInstallError.reservedID("shelf")) { try setup.store.install(reserved) }

        #expect(setup.installedPackages().isEmpty)
        #expect(setup.runtime.blocks.isEmpty)
        #expect(setup.launcher.processes.isEmpty)
    }

    @Test func updateKeepsPlaceSettingsAndData() async throws {
        let setup = Setup()
        let other = OtherBlock()
        setup.runtime.register(other)
        try setup.store.install(try setup.package(version: "0.2", events: ["pointerHover"]))
        setup.runtime.register(OtherBlockAfter())
        let block = try #require(setup.block("hello"))
        try await setup.launcher.last!.start()
        let first = try #require(setup.launcher.last)
        setup.defaults.set(true, forKey: "hello.loud")
        setup.defaults.set(true, forKey: "block.hello.enabled")
        let data = setup.dataRoot.appending(path: "hello")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: data.appending(path: "state"))

        let newer = try setup.package(version: "0.3", events: ["pointerHover", "outputVolume"])
        let summary = try setup.store.inspect(newer)
        #expect(summary.installedVersion == "0.2")
        #expect(summary.newEvents == ["Volume changes"])

        try setup.store.install(newer)

        #expect(setup.runtime.blocks.map(\.id) == ["other", "hello", "after"])
        #expect(setup.block("hello") === block, "the same stand-in, swapped in place")
        #expect(block.manifest.version == "0.3")
        #expect(block.info.version == "0.3")
        #expect(block.info.source == .installed(from: newer.path))
        #expect(setup.installedPackages() == ["hello.topblock"])
        let installed = try bundleManifest(setup.blocksRoot.appending(path: "hello.topblock"))
        #expect(installed.version == "0.3")
        #expect(setup.defaults.bool(forKey: "hello.loud"))
        #expect(setup.defaults.object(forKey: "block.hello.enabled") != nil)
        #expect(try Data(contentsOf: data.appending(path: "state")) == Data("kept".utf8))
        #expect(setup.cleared.isEmpty)

        // Restarted: the old process was told to stop, a new one started.
        #expect(await first.waitFor { $0 == .quit } != nil)
        #expect(setup.launcher.processes.count == 2)
        #expect(setup.runtime.isEnabled("hello"))
        // The new event reaches the new process.
        try await setup.launcher.last!.start()
        setup.runtime.publish(OutputVolumeChanged(volume: 0.5, isMuted: false))
        await waitUntil { setup.launcher.last!.events.count == 1 }
        #expect(setup.launcher.last!.events.first?.payload.name == .outputVolume)
    }

    /// An update that drops an event no longer counts as listening to it, so
    /// the event's source can stop; the events it keeps still have it.
    @Test func updateThatDropsAnEventDropsItsDemand() throws {
        let setup = Setup()
        try setup.store.install(try setup.package(version: "0.2", events: ["pointerHover", "outputVolume"]))
        #expect(setup.runtime.hasSubscribers(for: OutputVolumeChanged.self))
        #expect(setup.runtime.hasSubscribers(for: PointerHoverChanged.self))

        try setup.store.install(try setup.package(version: "0.3", events: ["pointerHover"]))

        #expect(!setup.runtime.hasSubscribers(for: OutputVolumeChanged.self))
        #expect(setup.runtime.hasSubscribers(for: PointerHoverChanged.self))
        #expect(setup.runtime.isEnabled("hello"))
    }

    @Test func failedCopyKeepsOldPackage() async throws {
        let setup = Setup()
        try setup.store.install(try setup.package(version: "0.2"))
        let block = try #require(setup.block("hello"))
        try await setup.launcher.last!.start()
        let first = try #require(setup.launcher.last)

        // A file that cannot be read makes the copy fail.
        let newer = try setup.package(version: "0.3")
        let locked = newer.appending(path: "locked")
        try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        #expect {
            try setup.store.install(newer)
        } throws: { error in
            if case .copyFailed = error as? BlockInstallError { true } else { false }
        }

        #expect(block.manifest.version == "0.2")
        let installed = try bundleManifest(setup.blocksRoot.appending(path: "hello.topblock"))
        #expect(installed.version == "0.2")
        #expect(setup.installedPackages() == ["hello.topblock"], "no temporary copy is left")
        #expect(setup.launcher.processes.count == 1)
        #expect(block.isWelcomed, "the old version keeps running")
        #expect(!first.received.contains(.quit))
    }

    @Test func removeDeletesEverything() async throws {
        let setup = Setup()
        try setup.store.install(try setup.package())
        let first = try #require(setup.launcher.last)
        try await first.start()
        setup.defaults.set(true, forKey: "hello.loud")
        setup.defaults.set(true, forKey: "block.hello.enabled")
        setup.defaults.set("Stopped.", forKey: "block.hello.failure")
        setup.defaults.set(true, forKey: "shelf.keep")
        let data = setup.dataRoot.appending(path: "hello")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        try setup.store.remove("hello")

        #expect(setup.installedPackages().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: data.path))
        #expect(setup.defaults.object(forKey: "hello.loud") == nil)
        #expect(setup.defaults.object(forKey: "block.hello.enabled") == nil)
        #expect(setup.defaults.object(forKey: "block.hello.failure") == nil)
        #expect(setup.defaults.object(forKey: "block.hello.installedFrom") == nil)
        #expect(setup.defaults.bool(forKey: "shelf.keep"))
        #expect(setup.cleared == ["hello"])
        #expect(setup.runtime.blocks.isEmpty)
        #expect(!setup.store.canRemove("hello"))
        #expect(await first.waitFor { $0 == .quit } != nil)
    }

    @Test func bundledAndBuiltInCannotBeRemoved() throws {
        let setup = Setup()
        let bundled = setup.root.appending(path: "Bundled")
        let nowPlaying = bundled.appending(path: "NowPlaying.topblock")
        let source = try setup.package(id: "nowplaying")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: nowPlaying)
        let store = setup.makeStore(bundledRoot: bundled)
        for block in store.standIns(developmentPath: nil) { setup.runtime.register(block) }

        for id: BlockID in ["nowplaying", "shelf"] {
            #expect(!store.canRemove(id))
            #expect(throws: BlockInstallError.notRemovable(id.rawValue)) { try store.remove(id) }
        }
        #expect(FileManager.default.fileExists(atPath: nowPlaying.path))
        #expect(setup.runtime.blocks.map(\.id) == ["nowplaying"])
    }

    @Test func scanOrderIsBuiltInBundledInstalled() throws {
        let setup = Setup()
        let bundled = setup.root.appending(path: "Bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try setup.package(id: "nowplaying"), to: bundled.appending(path: "NowPlaying.topblock"))
        // Installed in an order that is not sorted.
        try setup.store.install(try setup.package(id: "zeta"))
        try setup.store.install(try setup.package(id: "alpha"))
        // Not a package, and a leftover temporary copy: both ignored.
        try FileManager.default.createDirectory(at: setup.blocksRoot.appending(path: "Notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: setup.blocksRoot.appending(path: ".alpha.topblock.incoming-1"), withIntermediateDirectories: true)

        let standIns = setup.makeStore(bundledRoot: bundled, checksRuntime: false).standIns(developmentPath: nil)

        #expect(standIns.map(\.id) == ["nowplaying", "alpha", "zeta"])
        #expect(standIns.map(\.info.source).first == .bundled)
    }

    // MARK: Ids are unique

    @Test func installOfDevelopmentBlockIdIsRefused() throws {
        let setup = Setup()
        let development = try setup.package(id: "hello")
        for block in setup.store.standIns(developmentPath: development.path) { setup.runtime.register(block) }
        let package = try setup.package(id: "hello")

        #expect(throws: BlockInstallError.idInUse("hello")) { try setup.store.inspect(package) }
        #expect(throws: BlockInstallError.idInUse("hello")) { try setup.store.install(package) }

        #expect(setup.installedPackages().isEmpty)
        #expect(setup.runtime.blocks.map(\.info.source) == [.development(path: development.path)])
        #expect(!setup.store.canRemove("hello"), "Remove never touches the development block")
        let text = try #require(BlockInstallError.idInUse("hello").errorDescription)
        #expect(text.contains("\"hello\""))
    }

    @Test func installOfRegisteredIdIsRefused() throws {
        let setup = Setup()
        setup.runtime.register(OtherBlock())

        #expect(throws: BlockInstallError.idInUse("other")) { try setup.store.install(try setup.package(id: "other")) }
        #expect(setup.installedPackages().isEmpty)
        #expect(setup.runtime.blocks.map(\.id) == ["other"])
    }

    // MARK: Refused at launch

    /// Puts a `hello` package this app refuses (contract 99) in the
    /// installed blocks folder, as an older app would have left it.
    private func refusedHello(_ setup: Setup) throws {
        try FileManager.default.createDirectory(at: setup.blocksRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try setup.package(contract: 99),
                                         to: setup.blocksRoot.appending(path: "hello.topblock"))
    }

    @Test func refusedPackageCanBeRemoved() throws {
        let setup = Setup()
        try refusedHello(setup)
        let store = setup.store
        for block in store.standIns(developmentPath: nil) { setup.runtime.register(block) }
        setup.defaults.set(true, forKey: "hello.loud")
        let data = setup.dataRoot.appending(path: "hello")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        #expect(setup.runtime.blocks.first is RefusedBlock)
        #expect(store.canRemove("hello"))
        try store.remove("hello")

        #expect(setup.installedPackages().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: data.path))
        #expect(setup.defaults.object(forKey: "hello.loud") == nil)
        #expect(setup.defaults.object(forKey: "block.hello.installedFrom") == nil)
        #expect(setup.cleared == ["hello"])
        #expect(setup.runtime.blocks.isEmpty)
        #expect(!store.canRemove("hello"))
    }

    @Test func installReplacesRefusedPackage() throws {
        let setup = Setup()
        try refusedHello(setup)
        let store = setup.store
        for block in store.standIns(developmentPath: nil) { setup.runtime.register(block) }
        #expect(setup.runtime.blocks.first is RefusedBlock)
        #expect(!store.canTurnOn("hello"))

        try store.install(try setup.package(version: "0.4"))

        let block = try #require(setup.block("hello"))
        #expect(block.manifest.version == "0.4")
        #expect(setup.runtime.blocks.count == 1)
        #expect(store.canTurnOn("hello"))
        #expect(setup.installedPackages() == ["hello.topblock"])
    }

    // MARK: Signature

    @Test func unsignedInstallIsRefusedUntilTheSwitchIsOn() throws {
        let setup = Setup()
        for result: PackageSignature in [.unsigned, .adHoc] {
            setup.signatures.set(result)
            let package = try setup.package()
            #expect(throws: BlockInstallError.unsigned) { try setup.store.inspect(package) }
            #expect(throws: BlockInstallError.unsigned) { try setup.store.install(package) }
        }
        #expect(setup.installedPackages().isEmpty)
        #expect(setup.runtime.blocks.isEmpty)

        // A broken seal is refused whatever the switch says.
        setup.defaults.set(true, forKey: BlockDefaultsKey.allowUnsigned)
        setup.signatures.set(.invalid(reason: "a file changed"))
        #expect(throws: BlockInstallError.badSignature("a file changed")) { try setup.store.install(try setup.package()) }

        setup.signatures.set(.adHoc)
        let package = try setup.package()
        let summary = try setup.store.inspect(package)
        #expect(!summary.isSigned)
        #expect(summary.signer == nil)
        try setup.store.install(package)
        #expect(setup.installedPackages() == ["hello.topblock"])
        #expect(setup.defaults.object(forKey: BlockStore.signerKey("hello")) == nil)
    }

    @Test func updateFromAnotherSignerIsRefused() async throws {
        let setup = Setup()
        try setup.store.install(try setup.package(version: "0.2"))
        let block = try #require(setup.block("hello"))

        setup.signatures.set(.valid(signer: "Someone Else", teamID: ""))
        let newer = try setup.package(version: "0.3")
        let expected = BlockInstallError.differentSigner(installed: FakeSignatures.signer, found: "Someone Else")
        #expect(throws: expected) { try setup.store.inspect(newer) }
        #expect(throws: expected) { try setup.store.install(newer) }

        // Unsigned, even with the switch on, does not replace a signed block.
        setup.defaults.set(true, forKey: BlockDefaultsKey.allowUnsigned)
        setup.signatures.set(.unsigned)
        #expect(throws: BlockInstallError.differentSigner(installed: FakeSignatures.signer, found: "no signature")) {
            try setup.store.install(newer)
        }

        #expect(block.manifest.version == "0.2")
        #expect(try bundleManifest(setup.blocksRoot.appending(path: "hello.topblock")).version == "0.2")

        // The same signer updates.
        setup.signatures.set(.valid(signer: FakeSignatures.signer, teamID: ""))
        try setup.store.install(newer)
        #expect(block.manifest.version == "0.3")
    }

    /// The installed copy is checked too: a source changed between its check
    /// and the copy installs nothing and leaves nothing behind.
    @Test func copyWithAnotherSignatureIsRefused() throws {
        let setup = Setup()
        // The source passes; the copy reports another signer.
        setup.signatures.queue([.valid(signer: FakeSignatures.signer, teamID: ""),
                                .valid(signer: "Someone Else", teamID: "")])
        #expect(throws: BlockInstallError.badSignature("the package changed while it was copied")) {
            try setup.store.install(try setup.package())
        }
        #expect(setup.installedPackages().isEmpty, "no package and no partial copy")
        #expect(setup.runtime.blocks.isEmpty)
        #expect(setup.defaults.object(forKey: BlockStore.signerKey("hello")) == nil)

        // The copy's seal is broken.
        setup.signatures.queue([.valid(signer: FakeSignatures.signer, teamID: ""), .invalid(reason: "a file changed")])
        #expect(throws: BlockInstallError.badSignature("a file changed")) {
            try setup.store.install(try setup.package())
        }
        #expect(setup.installedPackages().isEmpty)

        // Both checks agree: installed.
        try setup.store.install(try setup.package())
        #expect(setup.installedPackages() == ["hello.topblock"])
    }

    @Test func changedPackageIsRefusedAtLaunch() throws {
        let setup = Setup()
        try setup.store.install(try setup.package())

        // Changed on disk after install: the next launch refuses it.
        setup.signatures.set(.invalid(reason: "a sealed resource is modified"))
        let standIns = setup.makeStore(checksRuntime: false).standIns(developmentPath: nil)

        let refused = try #require(standIns.first as? RefusedBlock)
        #expect(standIns.count == 1)
        let reason = try #require(BlockInstallError.badSignature("a sealed resource is modified").errorDescription)
        #expect(refused.health == .turnedOff(reason: reason))

        // Unsigned at launch, with the switch off, is refused too.
        let unsignedSetup = Setup()
        unsignedSetup.defaults.set(true, forKey: BlockDefaultsKey.allowUnsigned)
        unsignedSetup.signatures.set(.unsigned)
        try unsignedSetup.store.install(try unsignedSetup.package())
        unsignedSetup.defaults.set(false, forKey: BlockDefaultsKey.allowUnsigned)
        let again = unsignedSetup.makeStore(checksRuntime: false).standIns(developmentPath: nil)
        #expect(again.first is RefusedBlock)
    }

    @Test func signerIsStoredAndClearedOnRemove() throws {
        let setup = Setup()
        let package = try setup.package()
        let summary = try setup.store.inspect(package)
        #expect(summary.isSigned)
        #expect(summary.signer == FakeSignatures.signer)

        try setup.store.install(package)
        #expect(setup.defaults.string(forKey: BlockStore.signerKey("hello")) == FakeSignatures.signer)
        #expect(setup.defaults.string(forKey: "block.hello.signer") == FakeSignatures.signer)

        try setup.store.remove("hello")
        #expect(setup.defaults.object(forKey: "block.hello.signer") == nil)
    }

    @Test func summaryAndInfoShowAccessInTheUsersWords() throws {
        let setup = Setup()
        let package = try setup.package()
        var manifest = try bundleManifest(package)
        manifest.access = [.network, .filesScreenshots]
        manifest.hosts = ["api.example.com", "*.example.org"]
        try Framing.encoder().encode(manifest).write(to: package.appending(path: "Contents/Resources/manifest.json"))

        let network = "Use the network, only to reach: api.example.com, *.example.org"
        let summary = try setup.store.inspect(package)
        #expect(summary.access == [network, "Rename files in the screenshot folder"])

        try setup.store.install(package)
        let block = try #require(setup.block("hello"))
        #expect(block.info.permissions == ["Nothing special", network, "Rename files in the screenshot folder"])
    }
}

/// A plain block registered after the installed one, to check its place.
@MainActor
private final class OtherBlockAfter: NotchBlock {
    let id: BlockID = "after"
    let title = "After"
    func activate(_ context: any BlockContext) {}
}
