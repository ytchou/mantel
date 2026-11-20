import BlockWire
import Foundation
import NotchCore
import os

/// Finds block packages, makes their stand-ins, and installs, updates and
/// removes the packages the user adds. The app makes one call to get the
/// stand-ins, registers them, and calls `stopAll()` when it quits.
///
/// Three kinds of package, in this order: the bundled blocks, shipped inside
/// the app bundle (now-playing); the installed blocks in `blocksRoot`; and
/// the development block, one package run from where it is, named with the
/// `-devBlock <path>` launch argument.
@MainActor
public final class BlockStore: BlockInstalling {
    private let owner: @MainActor () -> BlockID?
    private let blocksRoot: URL
    private let dataRoot: URL
    private let bundledRoot: URL?
    private let launcher: BlockLauncher
    private let defaults: UserDefaults
    private let turnOff: @MainActor (BlockID) -> Void
    private let register: @MainActor (any NotchBlock) -> Void
    private let unregister: @MainActor (BlockID) -> Void
    private let clearKeys: @MainActor (BlockID) -> Void
    private let isRegistered: @MainActor (BlockID) -> Bool
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "blocks")
    /// Every stand-in this store made, so `stopAll` can end their processes.
    private var made: [RemoteBlock] = []
    /// Installed packages refused at launch, listed so they can be removed.
    private var refused: [RefusedBlock] = []

    /// - Parameters:
    ///   - owner: who owns the notch now; pass `{ runtime.state.owner }`.
    ///     Each stand-in observes it to tell its block when it wins or loses the notch.
    ///   - blocksRoot: the folder of installed `<id>.topblock` packages.
    ///   - dataRoot: the folder holding one data folder per block.
    ///   - bundledRoot: the folder of `.topblock` packages shipped with the
    ///     app; the app passes `Contents/Resources/Blocks`. Nil for none.
    ///   - defaults: where block settings, turn-off reasons and install paths are stored.
    ///   - turnOff: turns a block off after repeated failures; the app passes
    ///     a closure that calls `BlockSettings.setEnabled(id, false, in:)`.
    ///   - register: adds a newly installed block to the runtime, on unless
    ///     the user turned it off.
    ///   - unregister: removes a block from the runtime; `runtime.unregister`.
    ///   - clearKeys: deletes a removed block's settings, `<id>.*` and
    ///     `block.<id>.*`; the app passes `BlockSettings.clear`.
    ///   - isRegistered: whether the runtime already has a block with this
    ///     id; the app passes `{ runtime.blocks.contains { $0.id == id } }`.
    ///     A package with such an id is refused, as the runtime would drop it.
    public init(
        owner: @escaping @MainActor () -> BlockID?,
        blocksRoot: URL,
        dataRoot: URL,
        bundledRoot: URL? = nil,
        launcher: @escaping BlockLauncher = { try BlockProcess.spawn(executable: $0, generation: $1) },
        defaults: UserDefaults = .standard,
        turnOff: @escaping @MainActor (BlockID) -> Void = { _ in },
        register: @escaping @MainActor (any NotchBlock) -> Void = { _ in },
        unregister: @escaping @MainActor (BlockID) -> Void = { _ in },
        clearKeys: @escaping @MainActor (BlockID) -> Void = { _ in },
        isRegistered: @escaping @MainActor (BlockID) -> Bool = { _ in false }
    ) {
        self.owner = owner
        self.blocksRoot = blocksRoot
        self.dataRoot = dataRoot
        self.bundledRoot = bundledRoot
        self.launcher = launcher
        self.defaults = defaults
        self.turnOff = turnOff
        self.register = register
        self.unregister = unregister
        self.clearKeys = clearKeys
        self.isRegistered = isRegistered
    }

    /// `~/Library/Application Support/TopNotch`.
    private nonisolated static var supportRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "TopNotch")
    }

    /// `~/Library/Application Support/TopNotch/Blocks`.
    public nonisolated static var defaultBlocksRoot: URL { supportRoot.appending(path: "Blocks") }

    /// `~/Library/Application Support/TopNotch/BlockData`.
    public nonisolated static var defaultDataRoot: URL { supportRoot.appending(path: "BlockData") }

    /// Where the path a block was installed from is kept. Under `block.<id>.`,
    /// so Remove clears it with the block's other keys.
    static func installedFromKey(_ id: String) -> String { "block.\(id).installedFrom" }

    /// The stand-ins to register, in order: the bundled blocks by folder
    /// name, the installed blocks by id, then the development block.
    /// `developmentPath` is a `.topblock` folder to run from where it is.
    ///
    /// A bundled or development package that is missing, or that
    /// `PackageValidator` refuses, is logged and left out. An installed
    /// package that is refused is listed as a `RefusedBlock`, turned off with
    /// the reason. An installed folder not named `<manifest id>.topblock`,
    /// and a package whose id an earlier one or the runtime already holds,
    /// are logged and left out.
    public func standIns(developmentPath: String?) -> [any NotchBlock] {
        var candidates: [any NotchBlock] = bundledBlocks()
        candidates += installedBlocks()
        if let developmentPath, let block = developmentBlock(at: developmentPath) {
            candidates.append(block)
        }
        var blocks: [any NotchBlock] = []
        for block in candidates {
            if blocks.contains(where: { $0.id == block.id }) || isHeld(block.id.rawValue) || isRegistered(block.id) {
                log.error("block \(block.id.rawValue, privacy: .public) skipped: another block already has this id")
                continue
            }
            blocks.append(block)
        }
        made += blocks.compactMap { $0 as? RemoteBlock }
        refused += blocks.compactMap { $0 as? RefusedBlock }
        return blocks
    }

    /// Ends every block process this store started and waits for each to exit.
    public func stopAll() {
        RemoteBlock.stopAll(made)
    }

    // MARK: BlockInstalling

    public func inspect(_ url: URL) throws -> BlockPackageSummary {
        let manifest = try PackageValidator.load(url, source: .installed(from: url.path))
        try checkAvailable(manifest.id)
        let installed = installedBlock(manifest.id)
        let events = manifest.events.compactMap(WireEvent.init(rawValue:))
        let oldEvents = Set(installed?.manifest.events ?? [])
        return BlockPackageSummary(
            id: BlockID(rawValue: manifest.id),
            name: manifest.name,
            version: manifest.version,
            contract: manifest.contract,
            events: events.map(Self.eventText),
            newEvents: installed == nil ? [] : events.filter { !oldEvents.contains($0.rawValue) }.map(Self.eventText),
            permissions: manifest.permissions,
            sourcePath: url.path,
            installedVersion: installed?.manifest.version
        )
    }

    /// Copies the package to `<blocksRoot>/<id>.topblock` and registers its
    /// stand-in. For an installed id this is an update: the folder is
    /// replaced in one step and the existing stand-in takes the new package,
    /// keeping its place, settings and data. An installed package refused at
    /// launch is replaced by the new one. A refused package, an id another
    /// block already has, or a copy that fails, changes nothing.
    public func install(_ url: URL) throws {
        let source = BlockSource.installed(from: url.path)
        let manifest = try PackageValidator.load(url, source: source)
        try checkAvailable(manifest.id)
        let destination = blocksRoot.appending(path: "\(manifest.id).topblock", directoryHint: .isDirectory)
        // Copied beside the destination first, so a failed copy leaves the
        // installed version untouched. Its extension is not `.topblock`, so a
        // leftover is never scanned.
        let incoming = blocksRoot.appending(path: ".\(manifest.id).topblock.incoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: blocksRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: incoming)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            log.error("copy of \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw BlockInstallError.copyFailed(error.localizedDescription)
        }

        let existing = installedBlock(manifest.id)
        let old = existing.map { ($0.manifest, $0.source) }
        // The old process may still read its files; stop it before the swap.
        existing?.stop()
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: incoming)
            } else {
                try FileManager.default.moveItem(at: incoming, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            if let existing, let old { existing.replacePackage(manifest: old.0, source: old.1) }
            log.error("install of \(manifest.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw BlockInstallError.copyFailed(error.localizedDescription)
        }
        defaults.set(url.path, forKey: Self.installedFromKey(manifest.id))

        if let existing {
            log.info("updated \(manifest.id, privacy: .public) to \(manifest.version, privacy: .public)")
            existing.replacePackage(manifest: manifest, source: source)
        } else {
            log.info("installed \(manifest.id, privacy: .public) \(manifest.version, privacy: .public) from \(url.path, privacy: .public)")
            if let placeholder = refusedBlock(manifest.id) {
                unregister(placeholder.id)
                refused.removeAll { $0 === placeholder }
            }
            let block = standIn(manifest: manifest, package: destination, source: source)
            made.append(block)
            register(block)
        }
    }

    /// Stops and unregisters an installed block, or one refused at launch,
    /// then deletes its package, its data folder and its settings keys.
    public func remove(_ id: BlockID) throws {
        let package: URL
        if let block = installedBlock(id.rawValue) {
            block.stop()
            made.removeAll { $0 === block }
            package = block.packageURL
        } else if let placeholder = refusedBlock(id.rawValue) {
            refused.removeAll { $0 === placeholder }
            package = placeholder.packageURL
        } else {
            throw BlockInstallError.notRemovable(id.rawValue)
        }
        unregister(id)
        clearKeys(id)
        let data = dataRoot.appending(path: id.rawValue)
        if FileManager.default.fileExists(atPath: data.path) { try? FileManager.default.removeItem(at: data) }
        do {
            try FileManager.default.removeItem(at: package)
        } catch {
            log.error("removing \(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw BlockInstallError.copyFailed(error.localizedDescription)
        }
        log.info("removed \(id.rawValue, privacy: .public)")
    }

    public func canRemove(_ id: BlockID) -> Bool {
        installedBlock(id.rawValue) != nil || refusedBlock(id.rawValue) != nil
    }

    /// False for an installed package refused at launch: it cannot start.
    public func canTurnOn(_ id: BlockID) -> Bool {
        refusedBlock(id.rawValue) == nil
    }

    /// An event name in the user's words, for the install sheet.
    nonisolated static func eventText(_ event: WireEvent) -> String {
        switch event {
        case .pointerHover: "Pointer over the notch"
        case .outputVolume: "Volume changes"
        case .nowPlaying: "Music playing"
        case .screenshotCaptured: "Screenshots"
        case .dragStarted: "Dragging starts"
        case .dragEnded: "Dragging ends"
        }
    }

    // MARK: Scanning

    /// The stand-in of an installed block with this id, if any.
    private func installedBlock(_ id: String) -> RemoteBlock? {
        made.first { block in
            guard block.id.rawValue == id, case .installed = block.source else { return false }
            return true
        }
    }

    /// The placeholder of an installed package refused at launch, if any.
    private func refusedBlock(_ id: String) -> RefusedBlock? {
        refused.first { $0.id.rawValue == id }
    }

    /// True when this store already has a stand-in or placeholder with this id.
    private func isHeld(_ id: String) -> Bool {
        made.contains { $0.id.rawValue == id } || refusedBlock(id) != nil
    }

    /// Refuses an id that a bundled or development block, or a block outside
    /// this store, already has. An installed id passes: installing it updates.
    private func checkAvailable(_ id: String) throws(BlockInstallError) {
        if installedBlock(id) != nil || refusedBlock(id) != nil { return }
        if isHeld(id) || isRegistered(BlockID(rawValue: id)) { throw .idInUse(id) }
    }

    /// Every `.topblock` folder in `bundledRoot`, sorted by name.
    private func bundledBlocks() -> [RemoteBlock] {
        guard let bundledRoot else { return [] }
        return packages(in: bundledRoot, kind: "bundled")
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { block(at: $0, source: .bundled, kind: "bundled") }
    }

    /// Every `<id>.topblock` folder in `blocksRoot`, sorted by id. A package
    /// the validator refuses becomes a `RefusedBlock`. A folder whose name is
    /// not a valid id, or not its manifest's id, is logged and left out.
    private func installedBlocks() -> [any NotchBlock] {
        packages(in: blocksRoot, kind: "installed")
            .compactMap { package -> (any NotchBlock)? in
                let id = package.deletingPathExtension().lastPathComponent
                // The original path is shown on the Blocks page; the copy is what runs.
                let from = defaults.string(forKey: Self.installedFromKey(id)) ?? package.path
                let source = BlockSource.installed(from: from)
                do {
                    try PackageValidator.checkID(id, source: source)
                } catch {
                    log.error("installed block at \(package.path, privacy: .public) skipped: its folder name is not a block id")
                    return nil
                }
                let decoded = try? Manifest.decode(Data(contentsOf: PackageValidator.manifestURL(in: package)))
                if let decoded, decoded.id != id {
                    log.error("installed block at \(package.path, privacy: .public) skipped: its manifest id is \(decoded.id, privacy: .public)")
                    return nil
                }
                do throws(BlockInstallError) {
                    let manifest = try PackageValidator.load(package, source: source)
                    log.info("installed block \(id, privacy: .public) \(manifest.version, privacy: .public) from \(package.path, privacy: .public)")
                    return standIn(manifest: manifest, package: package, source: source)
                } catch {
                    let reason = error.errorDescription ?? String(describing: error)
                    log.error("installed block \(id, privacy: .public) turned off: \(reason, privacy: .public)")
                    return RefusedBlock(id: BlockID(rawValue: id), title: decoded?.name ?? id,
                                        packageURL: package, source: source, reason: reason)
                }
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func packages(in folder: URL, kind: String) -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "topblock" }
        } catch {
            log.error("no \(kind, privacy: .public) blocks at \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func developmentBlock(at path: String) -> RemoteBlock? {
        let package = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return block(at: package, source: .development(path: package.path), kind: "development")
    }

    /// A stand-in for the package, or nil, logged, when it does not validate.
    private func block(at package: URL, source: BlockSource, kind: String) -> RemoteBlock? {
        let manifest: Manifest
        do {
            manifest = try PackageValidator.load(package, source: source)
        } catch {
            log.error("\(kind, privacy: .public) block at \(package.path, privacy: .public) not loaded: \(error.errorDescription ?? String(describing: error), privacy: .public)")
            return nil
        }
        log.info("\(kind, privacy: .public) block \(manifest.id, privacy: .public) \(manifest.version, privacy: .public) from \(package.path, privacy: .public)")
        return standIn(manifest: manifest, package: package, source: source)
    }

    private func standIn(manifest: Manifest, package: URL, source: BlockSource) -> RemoteBlock {
        RemoteBlock(
            manifest: manifest,
            packageURL: package,
            source: source,
            dataFolder: dataRoot.appending(path: manifest.id),
            owner: owner,
            launcher: launcher,
            defaults: defaults,
            turnOff: turnOff
        )
    }
}
