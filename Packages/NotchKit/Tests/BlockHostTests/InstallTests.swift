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
        var approvalsFile: URL { root.appending(path: "Approvals.json") }
        /// The approvals the store keeps, read from its file.
        var approvals: ApprovalStore { ApprovalStore(file: approvalsFile) }
        lazy var store = makeStore()

        /// - Parameter checksRuntime: false for a second store that only scans
        ///   the folders, so the blocks the first one registered do not count.
        func makeStore(checksRuntime: Bool = true) -> BlockStore {
            let store = BlockStore(
                owner: { [runtime] in runtime.state.owner },
                blocksRoot: blocksRoot,
                dataRoot: dataRoot,
                launcher: launcher.launcher,
                defaults: defaults,
                approvalsFile: approvalsFile,
                // As the app wires them: on/off is the stored value, a block with none is on.
                turnOn: { [runtime, defaults] id in
                    defaults.set(true, forKey: "block.\(id.rawValue).enabled")
                    runtime.setEnabled(id, true)
                },
                register: { [weak self, runtime] block in runtime.register(block, enabled: self?.isOn(block.id) ?? true) },
                replace: { [weak self, runtime] block in runtime.replace(block, enabled: self?.isOn(block.id) ?? true) },
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

        /// The stored on/off value, as `BlockSettings.isEnabled` reads it.
        func isOn(_ id: BlockID) -> Bool {
            defaults.object(forKey: "block.\(id.rawValue).enabled") == nil || defaults.bool(forKey: "block.\(id.rawValue).enabled")
        }

        /// A `<folder>/<Name>.topblock` bundle outside the store, with an executable script.
        /// - Parameter hosts: when not empty, the manifest asks for `network` to reach them.
        func package(
            id: String = "hello", version: String = "0.2", events: [String] = ["pointerHover"],
            contract: Int = Contract.current, folder: String = "hello-block", hosts: [String] = []
        ) throws -> URL {
            let url = root.appending(path: "source-\(UUID().uuidString)").appending(path: folder)
                .appending(path: "Hello.topblock")
            var manifest = Manifest(id: id, name: "Hello", version: version, contract: contract, executable: "HelloBlock",
                                    summary: "Says hello.", trigger: "Pointer hover",
                                    permissions: ["Nothing special"], events: events,
                                    settings: [SettingSpec(key: "loud", type: .toggle, title: "Loud", default: .bool(false))])
            if !hosts.isEmpty {
                manifest.access = [.network]
                manifest.hosts = hosts
            }
            try writeBundle(at: url, manifest: manifest)
            return url
        }

        /// Copies `package` into the Blocks folder as `folder`, as the owner
        /// would in Finder. Returns the copy.
        @discardableResult
        func drop(_ package: URL, as folder: String = "Hello.topblock") throws -> URL {
            let copy = blocksRoot.appending(path: folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: blocksRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: package, to: copy)
            return copy
        }

        /// The app at launch: the store's stand-ins, registered in `runtime`.
        @discardableResult
        func launch(developmentPath: String? = nil) -> [any NotchBlock] {
            let blocks = store.standIns(developmentPath: developmentPath)
            for block in blocks { runtime.register(block, enabled: isOn(block.id)) }
            return blocks
        }

        /// What the next launch finds, from a new store over the same folders.
        func relaunch() -> [any NotchBlock] {
            makeStore(checksRuntime: false).standIns(developmentPath: nil)
        }

        /// Adds one byte to the executable of `package`, as a rebuild or a
        /// tampering would change it.
        nonisolated static func changeOneByte(in package: URL) throws {
            let executable = package.appending(path: "Contents/MacOS/HelloBlock")
            let handle = try FileHandle(forWritingTo: executable)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("#".utf8))
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
        #expect(summary.eventEntries.map(\.name) == ["Pointer over the notch", "Volume changes"])
        #expect(summary.packageHash == PackageHash.of(package))
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
        let reserved = try setup.package(id: "onboarding")
        #expect(throws: BlockInstallError.reservedID("onboarding")) { try setup.store.install(reserved) }

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

    @Test func builtInCannotBeRemoved() throws {
        let setup = Setup()
        setup.runtime.register(OtherBlock())

        #expect(!setup.store.canRemove("other"))
        #expect(throws: BlockInstallError.notRemovable("other")) { try setup.store.remove("other") }
        #expect(setup.runtime.blocks.map(\.id) == ["other"])
    }

    @Test func scanOrderIsInstalledById() throws {
        let setup = Setup()
        // Installed in an order that is not sorted.
        try setup.store.install(try setup.package(id: "zeta"))
        try setup.store.install(try setup.package(id: "alpha"))
        // Not a package, and a leftover temporary copy: both ignored.
        try FileManager.default.createDirectory(at: setup.blocksRoot.appending(path: "Notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: setup.blocksRoot.appending(path: ".alpha.topblock.incoming-1"), withIntermediateDirectories: true)

        let standIns = setup.makeStore(checksRuntime: false).standIns(developmentPath: nil)

        #expect(standIns.map(\.id) == ["alpha", "zeta"])
    }

    /// The ids of the blocks that left the app are free: a package with one
    /// installs, waits for approval when dropped in the folder, and runs like any other.
    @Test func aFormerlyBundledIdInstallsLikeAnyOther() throws {
        let setup = Setup()
        try setup.store.install(try setup.package(id: "shelf"))
        #expect(setup.block("shelf") != nil)
        #expect(setup.launcher.processes.count == 1)

        let dropped = Setup()
        let copy = try dropped.drop(try dropped.package(id: "shelf"))
        let pending = try #require(dropped.launch().first as? PendingBlock)
        #expect(pending.id == "shelf")
        #expect(pending.review == .new)
        #expect(dropped.launcher.processes.isEmpty)
        try dropped.store.approve("shelf", expectedHash: try dropped.store.inspect(copy).packageHash)
        #expect(dropped.block("shelf") != nil)
        #expect(dropped.launcher.processes.count == 1)
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

    @Test func anUnsignedPackageIsApprovedForThatBuildOnly() throws {
        let setup = Setup()
        setup.signatures.set(.unsigned)
        let dropped = try setup.drop(try setup.package())
        #expect(setup.launch().first is PendingBlock)
        let summary = try setup.store.inspect(dropped)
        #expect(!summary.isSigned)
        #expect(summary.signer == nil)

        // Approved with no switch: this build runs, with no signer recorded.
        try setup.store.approve("hello", expectedHash: summary.packageHash)
        #expect(setup.block("hello") != nil)
        #expect(setup.launcher.processes.count == 1)
        let approval = try #require(setup.approvals.approval(for: "hello"))
        #expect(approval.signer == nil)
        #expect(setup.relaunch().first is RemoteBlock, "the same build runs at the next launch")

        // Rebuilt: another build, so it asks again.
        try Setup.changeOneByte(in: dropped)
        let again = try #require(setup.relaunch().first as? PendingBlock)
        #expect(again.review == .changed)

        // Ad hoc from the sheet: installed and approved in one step.
        let adHoc = Setup()
        adHoc.signatures.set(.adHoc)
        try adHoc.store.install(try adHoc.package())
        #expect(adHoc.block("hello") != nil)
        #expect(adHoc.approvals.approval(for: "hello")?.signer == nil)

        // A broken seal is refused whatever else is true.
        let broken = Setup()
        broken.signatures.set(.invalid(reason: "a file changed"))
        #expect(throws: BlockInstallError.badSignature("a file changed")) { try broken.store.install(try broken.package()) }
        #expect(broken.installedPackages().isEmpty)
    }

    @Test func theOldSwitchHasNoEffect() throws {
        let setup = Setup()
        // The key the removed "Allow blocks without a signature" switch wrote.
        setup.defaults.set(true, forKey: "block.allowUnsigned")
        setup.signatures.set(.unsigned)
        try setup.drop(try setup.package())

        let blocks = setup.launch()

        #expect(blocks.first is PendingBlock)
        #expect(setup.launcher.processes.isEmpty)
        #expect(setup.approvals.approval(for: "hello") == nil)
    }

    @Test func anUpdateFromAnotherSignerIsStillRefused() async throws {
        let setup = Setup()
        try setup.store.install(try setup.package(version: "0.2"))
        let block = try #require(setup.block("hello"))
        #expect(setup.approvals.approval(for: "hello")?.signer == FakeSignatures.signer)
        #expect(setup.defaults.object(forKey: "block.hello.signer") == nil, "the signer is kept in the approval")

        setup.signatures.set(.valid(signer: "Someone Else", teamID: ""))
        let newer = try setup.package(version: "0.3")
        let expected = BlockInstallError.differentSigner(installed: FakeSignatures.signer, found: "Someone Else")
        #expect(throws: expected) { try setup.store.inspect(newer) }
        #expect(throws: expected) { try setup.store.install(newer) }
        #expect(block.manifest.version == "0.2")
        #expect(try bundleManifest(setup.blocksRoot.appending(path: "hello.topblock")).version == "0.2")

        // Changed on disk and signed by someone else: approving it is refused too.
        try Setup.changeOneByte(in: setup.blocksRoot.appending(path: "hello.topblock"))
        let next = setup.makeStore(checksRuntime: false)
        #expect(next.standIns(developmentPath: nil).first is PendingBlock)
        let changed = PackageHash.of(setup.blocksRoot.appending(path: "hello.topblock"))
        #expect(throws: expected) { try next.approve("hello", expectedHash: changed) }

        // The same signer updates.
        setup.signatures.set(.valid(signer: FakeSignatures.signer, teamID: ""))
        try setup.store.install(newer)
        #expect(block.manifest.version == "0.3")
    }

    @Test func anUnsignedUpdateOfASignedBlockIsStillRefused() throws {
        let setup = Setup()
        try setup.store.install(try setup.package(version: "0.2"))
        let block = try #require(setup.block("hello"))

        for result: PackageSignature in [.unsigned, .adHoc] {
            setup.signatures.set(result)
            let newer = try setup.package(version: "0.3")
            let expected = BlockInstallError.differentSigner(installed: FakeSignatures.signer, found: "no signature")
            #expect(throws: expected) { try setup.store.inspect(newer) }
            #expect(throws: expected) { try setup.store.install(newer) }
        }
        #expect(block.manifest.version == "0.2")
        #expect(setup.approvals.approval(for: "hello")?.signer == FakeSignatures.signer)
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
        #expect(setup.approvals.approval(for: "hello") == nil)

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

        // Its seal broken on disk after install: the next launch refuses it.
        setup.signatures.set(.invalid(reason: "a sealed resource is modified"))
        let standIns = setup.relaunch()

        let refused = try #require(standIns.first as? RefusedBlock)
        #expect(standIns.count == 1)
        let reason = try #require(BlockInstallError.badSignature("a sealed resource is modified").errorDescription)
        #expect(refused.health == .turnedOff(reason: reason))
    }

    // MARK: Approval

    @Test func aPackageFoundInTheFolderIsPendingAndNotStarted() throws {
        let setup = Setup()
        try setup.drop(try setup.package())

        let blocks = setup.launch()

        let pending = try #require(blocks.first as? PendingBlock)
        #expect(blocks.count == 1)
        #expect(pending.id == "hello")
        #expect(pending.title == "Hello")
        #expect(pending.review == .new)
        #expect(pending.health == .turnedOff(reason: PendingBlock.reason(.new)))
        #expect(setup.launcher.processes.isEmpty, "nothing started")
        #expect(!setup.store.canTurnOn("hello"))
        #expect(setup.store.canRemove("hello"))
        #expect(setup.approvals.approval(for: "hello") == nil)
    }

    @Test func approvingAPendingBlockStartsIt() throws {
        let setup = Setup()
        let dropped = try setup.drop(try setup.package(hosts: ["api.example.com"]))
        setup.runtime.register(OtherBlock())
        setup.launch()
        setup.runtime.register(OtherBlockAfter())
        #expect(setup.runtime.blocks.map(\.id) == ["other", "hello", "after"])
        // The sheet reviews the package where it is.
        let summary = try setup.store.inspect(dropped)
        #expect(summary.id == "hello")
        #expect(summary.signer == FakeSignatures.signer)

        try setup.store.approve("hello", expectedHash: summary.packageHash)

        let block = try #require(setup.block("hello"))
        #expect(setup.runtime.blocks.map(\.id) == ["other", "hello", "after"], "in the placeholder's place")
        #expect(block.packageURL.lastPathComponent == "Hello.topblock", "it runs where it was found")
        #expect(setup.runtime.isEnabled("hello"))
        #expect(setup.launcher.processes.count == 1, "the block process was started")
        let approval = try #require(setup.approvals.approval(for: "hello"))
        #expect(approval.hash == PackageHash.of(dropped))
        #expect(approval.signer == FakeSignatures.signer)
        #expect(approval.hosts == ["api.example.com"])
        #expect(setup.defaults.object(forKey: "block.hello.signer") == nil)
        #expect(setup.store.canTurnOn("hello"))
        #expect(throws: BlockInstallError.nothingToApprove("hello")) {
            try setup.store.approve("hello", expectedHash: summary.packageHash)
        }
        #expect(setup.relaunch().first is RemoteBlock, "the next launch runs it without asking")
    }

    @Test func installFromTheSheetApprovesInOneStep() throws {
        let setup = Setup()
        let package = try setup.package()

        try setup.store.install(package)

        let block = try #require(setup.block("hello"))
        #expect(setup.runtime.isEnabled("hello"))
        #expect(setup.launcher.processes.count == 1)
        let approval = try #require(setup.approvals.approval(for: "hello"))
        #expect(approval.hash == PackageHash.of(block.packageURL))
        #expect(approval.hash == PackageHash.of(package), "the copy is the build the owner chose")
        #expect(approval.signer == FakeSignatures.signer)
        #expect(setup.relaunch().first is RemoteBlock)
    }

    @Test func aChangedPackageIsPendingAgain() throws {
        let setup = Setup()
        try setup.store.install(try setup.package())
        #expect(setup.launcher.processes.count == 1)

        try Setup.changeOneByte(in: setup.blocksRoot.appending(path: "hello.topblock"))
        let blocks = setup.relaunch()
        let relaunched = NotchRuntime()
        for block in blocks { relaunched.register(block) }

        let pending = try #require(blocks.first as? PendingBlock)
        #expect(pending.review == .changed)
        #expect(pending.health == .turnedOff(reason: PendingBlock.reason(.changed)))
        #expect(setup.launcher.processes.count == 1, "nothing started after the change")
    }

    @Test func aDevelopmentBlockNeedsNoApproval() throws {
        let setup = Setup()
        setup.signatures.set(.unsigned)
        let development = try setup.package()

        let blocks = setup.launch(developmentPath: development.path)

        let block = try #require(blocks.first as? RemoteBlock)
        #expect(block.info.source == .development(path: development.path))
        #expect(setup.launcher.processes.count == 1)
        #expect(!FileManager.default.fileExists(atPath: setup.approvalsFile.path), "no record is written")
    }

    @Test func removeDeletesTheApproval() throws {
        let setup = Setup()
        try setup.store.install(try setup.package())
        #expect(setup.approvals.approval(for: "hello") != nil)

        try setup.store.remove("hello")

        #expect(setup.approvals.approval(for: "hello") == nil)
        #expect(setup.installedPackages().isEmpty)

        // A pending block can be removed too, package and all.
        let pending = Setup()
        try pending.drop(try pending.package())
        pending.launch()
        try pending.store.remove("hello")
        #expect(pending.installedPackages().isEmpty)
        #expect(pending.runtime.blocks.isEmpty)
    }

    /// A block installed by an earlier version has its signer in the
    /// preferences and no approval: it is approved once, as it is now, so
    /// the owner's block keeps running.
    @Test func anInstalledBlockFromAnEarlierVersionIsApprovedOnce() throws {
        let setup = Setup()
        let installed = try setup.drop(try setup.package(), as: "hello.topblock")
        setup.defaults.set(FakeSignatures.signer, forKey: "block.hello.signer")

        let blocks = setup.launch()

        #expect(blocks.first is RemoteBlock)
        #expect(setup.launcher.processes.count == 1)
        let approval = try #require(setup.approvals.approval(for: "hello"))
        #expect(approval.hash == PackageHash.of(installed))
        #expect(approval.signer == FakeSignatures.signer)
        #expect(setup.defaults.object(forKey: "block.hello.signer") == nil, "read once")

        // Signed by someone else than the stored signer: refused, as before.
        let other = Setup()
        try other.drop(try other.package(), as: "hello.topblock")
        other.defaults.set("Someone Else", forKey: "block.hello.signer")
        #expect(other.launch().first is RefusedBlock)
        #expect(other.approvals.approval(for: "hello") == nil)
    }

    /// The sheet lists the hosts on their own row ("Can reach"), so its
    /// access line for `network` does not repeat them; the Blocks page does.
    @Test func summaryAndInfoShowAccessInTheUsersWords() throws {
        let setup = Setup()
        let package = try setup.package()
        try Self.setAccess([.network, .filesScreenshots], hosts: ["api.example.com", "*.example.org"], of: package)

        let network = "Use the network, only to reach: api.example.com, *.example.org"
        let summary = try setup.store.inspect(package)
        #expect(summary.access == ["Use the network", "Rename files in the screenshot folder"])
        #expect(summary.hosts == ["api.example.com", "*.example.org"])

        try setup.store.install(package)
        let block = try #require(setup.block("hello"))
        #expect(block.info.permissions == ["Nothing special", network, "Rename files in the screenshot folder"])
    }

    /// Rewrites the manifest of `package` with this access and these hosts.
    private static func setAccess(_ access: [Access], hosts: [String], of package: URL) throws {
        var manifest = try bundleManifest(package)
        manifest.access = access
        manifest.hosts = hosts
        try Framing.encoder().encode(manifest).write(to: package.appending(path: "Contents/Resources/manifest.json"))
    }

    // MARK: The sheet's summary

    @Test func inspectFlagsTheRiskyPair() throws {
        let setup = Setup()
        let hosts = ["api.example.com"]

        let files = try setup.package()
        try Self.setAccess([.filesRead, .network], hosts: hosts, of: files)
        #expect(try setup.store.inspect(files).riskyPair == .files)

        let screenshots = try setup.package()
        try Self.setAccess([.network, .filesScreenshots], hosts: hosts, of: screenshots)
        #expect(try setup.store.inspect(screenshots).riskyPair == .screenshots)

        let networkOnly = try setup.package(hosts: hosts)
        #expect(try setup.store.inspect(networkOnly).riskyPair == nil)

        let filesOnly = try setup.package()
        try Self.setAccess([.filesRead], hosts: [], of: filesOnly)
        #expect(try setup.store.inspect(filesOnly).riskyPair == nil)
    }

    @Test func anUpdateThatAddsAHostNamesTheNewHost() throws {
        let setup = Setup()
        let first = try setup.inspectThenInstall(try setup.package(version: "0.2", hosts: ["api.example.com"]))
        #expect(first.hosts == ["api.example.com"])
        #expect(first.newHosts.isEmpty, "a new install has no new hosts")

        let update = try setup.store.inspect(try setup.package(version: "0.3", hosts: ["api.example.com", "cdn.example.com"]))

        #expect(update.hosts == ["api.example.com", "cdn.example.com"])
        #expect(update.newHosts == ["cdn.example.com"])
    }

    @Test func inspectSaysWhenAPackageIsUnsigned() throws {
        let setup = Setup()
        let package = try setup.package()
        #expect(try setup.store.inspect(package).isSigned)

        for result: PackageSignature in [.unsigned, .adHoc] {
            setup.signatures.set(result)
            let summary = try setup.store.inspect(package)
            #expect(!summary.isSigned)
            #expect(summary.signer == nil)
        }
    }

    /// A pending package is reviewed where it is, by id: the Blocks page
    /// does not know its folder.
    @Test func aPendingBlockIsReviewedByID() throws {
        let setup = Setup()
        let dropped = try setup.drop(try setup.package(hosts: ["api.example.com"]))
        setup.launch()

        let summary = try setup.store.reviewSummary("hello")

        #expect(summary.id == "hello")
        #expect(summary.sourcePath == dropped.path)
        #expect(summary.hosts == ["api.example.com"])
        #expect(throws: BlockInstallError.nothingToApprove("other")) { try setup.store.reviewSummary("other") }
    }

    // MARK: Review binds to the build shown (B3)

    @Test func anInstallOfAPackageChangedAfterReviewIsRefused() throws {
        let setup = Setup()
        let package = try setup.package()
        let summary = try setup.store.inspect(package)

        try Setup.changeOneByte(in: package)

        #expect(throws: BlockInstallError.changedDuringReview) {
            try setup.store.install(package, expectedHash: summary.packageHash)
        }
        #expect(setup.installedPackages().isEmpty, "no package and no partial copy")
        #expect(setup.runtime.blocks.isEmpty)
        #expect(setup.approvals.approval(for: "hello") == nil)
        #expect(setup.launcher.processes.isEmpty)
    }

    @Test func anApprovalOfAPackageChangedAfterReviewIsRefused() throws {
        let setup = Setup()
        let dropped = try setup.drop(try setup.package())
        setup.launch()
        let summary = try setup.store.reviewSummary("hello")

        try Setup.changeOneByte(in: dropped)

        #expect(throws: BlockInstallError.changedDuringReview) {
            try setup.store.approve("hello", expectedHash: summary.packageHash)
        }
        #expect(setup.runtime.blocks.first is PendingBlock, "still waiting for review")
        #expect(setup.approvals.approval(for: "hello") == nil)
        #expect(setup.launcher.processes.isEmpty)
        // Reviewed again, the build now there is approved.
        try setup.store.approve("hello", expectedHash: try setup.store.reviewSummary("hello").packageHash)
        #expect(setup.block("hello") != nil)
    }

    // MARK: "… and Turn On" (B4)

    /// A block the owner turned off whose package then changed: "Approve and
    /// Turn On" leaves it on, stored on, and running.
    @Test func approvingAChangedBlockThatWasOffTurnsItOn() throws {
        let setup = Setup()
        let dropped = try setup.drop(try setup.package())
        // Approved before, as another build; then turned off by the owner.
        try setup.approvals.approve(id: "hello", hash: Self.otherBuild, signer: FakeSignatures.signer,
                                    hosts: [], events: ["pointerHover"])
        setup.defaults.set(false, forKey: "block.hello.enabled")
        let pending = try #require(setup.launch().first as? PendingBlock)
        #expect(pending.review == .changed)

        try setup.store.approve("hello", expectedHash: PackageHash.of(dropped))

        #expect(setup.block("hello") != nil)
        #expect(setup.runtime.isEnabled("hello"))
        #expect(setup.isOn("hello"), "stored on, so the next launch starts it too")
        #expect(setup.launcher.processes.count == 1, "the block process was started")
    }

    /// "Install and Turn On" over a block waiting for review that was off
    /// turns it on; "Update" keeps a block that is off, off.
    @Test func installTurnsOnButAnUpdateKeepsOff() throws {
        let setup = Setup()
        try setup.drop(try setup.package(version: "0.1"))
        setup.defaults.set(false, forKey: "block.hello.enabled")
        #expect(setup.launch().first is PendingBlock)

        try setup.store.install(try setup.package(version: "0.2"))
        #expect(setup.runtime.isEnabled("hello"))
        #expect(setup.isOn("hello"))
        #expect(setup.launcher.processes.count == 1)

        setup.defaults.set(false, forKey: "block.hello.enabled")
        setup.runtime.setEnabled("hello", false)
        try setup.store.install(try setup.package(version: "0.3"))
        #expect(!setup.runtime.isEnabled("hello"))
        #expect(!setup.isOn("hello"))
        #expect(setup.launcher.processes.count == 1, "an update of a block that is off starts nothing")
    }

    // MARK: New events of a changed package (GS2)

    @Test func aChangedPackageThatAddsAnEventMarksItNew() throws {
        let setup = Setup()
        try setup.store.install(try setup.package(events: ["pointerHover"]))
        #expect(setup.approvals.approval(for: "hello")?.events == ["pointerHover"])

        // Rebuilt in place to also listen to screenshots: it waits as Changed.
        let installed = setup.blocksRoot.appending(path: "hello.topblock")
        var manifest = try bundleManifest(installed)
        manifest.events = ["pointerHover", "screenshotCaptured"]
        try Framing.encoder().encode(manifest).write(to: installed.appending(path: "Contents/Resources/manifest.json"))
        let next = setup.makeStore(checksRuntime: false)
        #expect((next.standIns(developmentPath: nil).first as? PendingBlock)?.review == .changed)

        let summary = try next.reviewSummary("hello")

        #expect(summary.newEvents == [EventCatalog.entry(for: .screenshotCaptured).name])
    }

    @Test func theFolderShownIsTheBlocksFolder() {
        let setup = Setup()
        #expect(setup.store.blocksFolder == setup.blocksRoot)
    }

    /// The SHA-256 of a build other than any package these tests make.
    static let otherBuild = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
}

extension BlockStore {
    /// Installs `url` as the sheet does after reading it: bound to the
    /// build at `url` now.
    func install(_ url: URL) throws {
        try install(url, expectedHash: PackageHash.of(url))
    }
}

extension InstallTests.Setup {
    /// Inspects `package` as the sheet does, then installs it.
    func inspectThenInstall(_ package: URL) throws -> BlockPackageSummary {
        let summary = try store.inspect(package)
        try store.install(package)
        return summary
    }
}

/// A plain block registered after the installed one, to check its place.
@MainActor
private final class OtherBlockAfter: NotchBlock {
    let id: BlockID = "after"
    let title = "After"
    func activate(_ context: any BlockContext) {}
}
