import BlockWire
import Foundation
import NotchCore
import os

/// Finds block packages, makes their stand-ins, and installs, updates and
/// removes the packages the user adds. The app makes one call to get the
/// stand-ins, registers them, and calls `stopAll()` when it quits.
///
/// Three kinds of package, in this order: the bundled blocks, shipped inside
/// the app bundle (Shelf, Now Playing, Screenshot Names); the installed
/// blocks in `blocksRoot`; and
/// the development block, one package run from where it is, named with the
/// `-devBlock <path>` launch argument. Every block runs sandboxed; only
/// installed packages have their signature checked (see `checkSignature`)
/// and need the owner's approval of their exact build (D9, D18): a package
/// found in `blocksRoot` without one, or changed since, is a `PendingBlock`
/// until `approve`.
@MainActor
public final class BlockStore: BlockInstalling {
    private let owner: @MainActor () -> BlockID?
    private let blocksRoot: URL
    private let dataRoot: URL
    private let oldDataRoot: URL?
    private let bundledRoot: URL?
    private let launcher: BlockLauncher?
    private let screenshotFolder: @MainActor () -> URL?
    private let defaults: UserDefaults
    private let turnOff: @MainActor (BlockID) -> Void
    private let turnOn: @MainActor (BlockID) -> Void
    private let register: @MainActor (any NotchBlock) -> Void
    private let replace: @MainActor (any NotchBlock) -> Void
    private let unregister: @MainActor (BlockID) -> Void
    private let clearKeys: @MainActor (BlockID) -> Void
    private let isRegistered: @MainActor (BlockID) -> Bool
    private let approvals: ApprovalStore
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "blocks")
    /// Every stand-in this store made, so `stopAll` can end their processes.
    private var made: [RemoteBlock] = []
    /// Stand-ins whose package was hashed against its approval moments ago:
    /// their next start check passes without hashing again (one hash per
    /// start). Filled only around the call that starts them, or, for the
    /// stand-ins found at launch, until the end of the current main-actor
    /// turn, in which the app registers them. Every later start hashes.
    private var justVerified: Set<ObjectIdentifier> = []
    /// Installed packages refused at launch, listed so they can be removed.
    private var refused: [RefusedBlock] = []
    /// Installed packages waiting for the owner's review.
    private var pending: [PendingBlock] = []
    /// Checks the signature of installed packages. Tests inject results.
    var signatures: any SignatureChecking = SystemSignatureChecker()

    /// - Parameters:
    ///   - owner: who owns the notch now; pass `{ runtime.state.owner }`.
    ///     Each stand-in observes it to tell its block when it wins or loses the notch.
    ///   - blocksRoot: the folder of installed `.topblock` packages, under any
    ///     folder name; the id comes from the manifest.
    ///   - dataRoot: the folder holding one data folder per block.
    ///   - oldDataRoot: the folder holding the data folders of the blocks that
    ///     ran inside the app, moved into `dataRoot` once. Nil means
    ///     `~/Library/Application Support/TopNotch` when `dataRoot` is the
    ///     default one, and no move for any other `dataRoot`.
    ///   - bundledRoot: the folder of `.topblock` packages shipped with the
    ///     app; the app passes `Contents/Resources/Blocks`. Nil for none.
    ///   - launcher: starts block processes; nil starts each one sandboxed
    ///     from its manifest's `access`. Tests pass in-memory processes.
    ///   - screenshotFolder: the folder `files.screenshots` opens; the app
    ///     passes the folder the screenshot watcher uses.
    ///   - defaults: where block settings, turn-off reasons and install paths
    ///     are stored.
    ///   - approvalsFile: the file of the owner's approvals. Nil means
    ///     `Approvals.json` beside `blocksRoot`; the app passes
    ///     `defaultApprovalsFile`.
    ///   - turnOff: turns a block off after repeated failures; the app passes
    ///     a closure that calls `BlockSettings.setEnabled(id, false, in:)`.
    ///   - turnOn: turns a block on and stores it on, after the owner
    ///     confirms "Install and Turn On" or "Approve and Turn On"; the app
    ///     passes a closure that calls `BlockSettings.setEnabled(id, true, in:)`.
    ///   - register: adds a newly installed block to the runtime, on unless
    ///     the user turned it off.
    ///   - replace: swaps the registered block with the same id for this
    ///     one, in its place; the app passes `runtime.replace`. Nil
    ///     unregisters the old one and registers the new one.
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
        oldDataRoot: URL? = nil,
        bundledRoot: URL? = nil,
        launcher: BlockLauncher? = nil,
        screenshotFolder: @escaping @MainActor () -> URL? = { nil },
        defaults: UserDefaults = .standard,
        approvalsFile: URL? = nil,
        turnOff: @escaping @MainActor (BlockID) -> Void = { _ in },
        turnOn: @escaping @MainActor (BlockID) -> Void = { _ in },
        register: @escaping @MainActor (any NotchBlock) -> Void = { _ in },
        replace: (@MainActor (any NotchBlock) -> Void)? = nil,
        unregister: @escaping @MainActor (BlockID) -> Void = { _ in },
        clearKeys: @escaping @MainActor (BlockID) -> Void = { _ in },
        isRegistered: @escaping @MainActor (BlockID) -> Bool = { _ in false }
    ) {
        self.owner = owner
        self.blocksRoot = blocksRoot
        self.dataRoot = dataRoot
        self.oldDataRoot = oldDataRoot ?? (dataRoot == Self.defaultDataRoot ? SupportFolder.root : nil)
        self.bundledRoot = bundledRoot
        self.launcher = launcher
        self.screenshotFolder = screenshotFolder
        self.defaults = defaults
        self.turnOff = turnOff
        self.turnOn = turnOn
        self.register = register
        self.replace = replace ?? { block in
            unregister(block.id)
            register(block)
        }
        self.unregister = unregister
        approvals = ApprovalStore(file: approvalsFile ?? blocksRoot.deletingLastPathComponent().appending(path: "Approvals.json"))
        self.clearKeys = clearKeys
        self.isRegistered = isRegistered
    }

    /// `~/Library/Application Support/TopNotch/Blocks`.
    public nonisolated static var defaultBlocksRoot: URL { SupportFolder.root.appending(path: "Blocks") }

    /// `~/Library/Application Support/TopNotch/BlockData`.
    public nonisolated static var defaultDataRoot: URL { SupportFolder.root.appending(path: "BlockData") }

    /// `~/Library/Application Support/TopNotch/Approvals.json`, which the
    /// sandbox closes to every block.
    public nonisolated static var defaultApprovalsFile: URL { SupportFolder.root.appending(path: "Approvals.json") }

    /// Where the path a block was installed from is kept. Under `block.<id>.`,
    /// so Remove clears it with the block's other keys.
    static func installedFromKey(_ id: String) -> String { "block.\(id).installedFrom" }

    /// Where earlier versions kept the signer of an installed block. Read
    /// once, by `migratedApproval`, and deleted; the signer now lives in the
    /// approval. Remove also deletes it.
    // Remove with `migratedApproval` two releases after approvals shipped.
    static func signerKey(_ id: String) -> String { "block.\(id).signer" }

    /// The stand-ins to register, in order: the bundled blocks by folder
    /// name, the installed blocks by id, then the development block.
    /// `developmentPath` is a `.topblock` folder to run from where it is.
    ///
    /// A bundled or development package that is missing, or that
    /// `PackageValidator` refuses, is logged and left out. An installed
    /// package that is refused is listed as a `RefusedBlock`, turned off with
    /// the reason; one not approved as it is now as a `PendingBlock`. A
    /// package whose id an earlier one or the runtime already holds is
    /// logged and left out.
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
        pending += blocks.compactMap { $0 as? PendingBlock }
        // The app registers the stand-ins in this turn; a start after it hashes again.
        justVerified.formIntersection(blocks.compactMap { ($0 as? RemoteBlock).map(ObjectIdentifier.init) })
        if !justVerified.isEmpty {
            Task { @MainActor [weak self] in self?.justVerified.removeAll() }
        }
        // Stand-ins start their processes only when registered, after this.
        if let oldDataRoot {
            Self.moveOldDataFolders(from: oldDataRoot, to: dataRoot,
                                    for: Set(blocks.compactMap { ($0 as? RemoteBlock)?.id.rawValue }))
        }
        return blocks
    }

    // MARK: Old data folders

    /// The data folders of the blocks that ran inside the app, next to
    /// `BlockData`, and the block id each now belongs to.
    // Remove this table and `moveOldDataFolders` two releases after Shelf and
    // Rename left the app: by then every Mac has moved its folders.
    static let oldDataFolders: [(folder: String, id: String)] = [("Shelf", "shelf"), ("Rename", "rename")]

    /// Moves each old data folder to `<dataRoot>/<id>`, once: only when the
    /// target does not exist yet. Only for `ids`, the blocks found at this
    /// launch, so a folder is moved only when its block is there to use it.
    static func moveOldDataFolders(from oldRoot: URL, to dataRoot: URL, for ids: Set<String>) {
        let files = FileManager.default
        let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "blocks")
        for (folder, id) in oldDataFolders where ids.contains(id) {
            let source = oldRoot.appending(path: folder, directoryHint: .isDirectory)
            let target = dataRoot.appending(path: id, directoryHint: .isDirectory)
            guard files.fileExists(atPath: source.path), !files.fileExists(atPath: target.path) else { continue }
            do {
                try files.createDirectory(at: dataRoot, withIntermediateDirectories: true)
                try files.moveItem(at: source, to: target)
                log.info("moved the old data folder \(folder, privacy: .public) to BlockData/\(id, privacy: .public)")
            } catch {
                log.error("moving the old data folder \(folder, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ends every block process this store started and waits for each to exit.
    public func stopAll() {
        RemoteBlock.stopAll(made)
    }

    // MARK: BlockInstalling

    /// Also reads a package waiting for review where it is in the Blocks
    /// folder, so the sheet can show it before `approve`.
    public func inspect(_ url: URL) throws -> BlockPackageSummary {
        // Hashed first: confirming the sheet installs or approves only this build.
        let hash = PackageHash.of(url)
        let manifest = try PackageValidator.load(url, source: .installed(from: url.path))
        try checkAvailable(manifest.id)
        let approval = approvals.approval(for: BlockID(rawValue: manifest.id))
        let signer = try checkSignature(url, pinned: approval?.signer)
        let installed = installedBlock(manifest.id)
        let events = manifest.events.compactMap(WireEvent.init(rawValue:))
        // What the owner approved last: the installed version's, or for a
        // package waiting for review after a change, its approval's. An
        // approval stored before events were kept has none, so every event
        // shows as new once. Nil for a new block: nothing is new.
        let oldEvents = installed?.manifest.events ?? approval?.events
        let oldHosts = installed?.manifest.hosts ?? approval?.hosts
        return BlockPackageSummary(
            id: BlockID(rawValue: manifest.id),
            name: manifest.name,
            version: manifest.version,
            contract: manifest.contract,
            packageHash: hash,
            newEvents: oldEvents.map { old in
                events.filter { !old.contains($0.rawValue) }.map { EventCatalog.entry(for: $0).name }
            } ?? [],
            eventEntries: events.map(EventCatalog.entry(for:)),
            permissions: manifest.permissions,
            sourcePath: url.path,
            installedVersion: installed?.manifest.version,
            access: manifest.sheetAccessText,
            signer: signer,
            hosts: manifest.hosts,
            newHosts: oldHosts.map { old in manifest.hosts.filter { !old.contains($0) } } ?? [],
            riskyPair: manifest.riskyPair
        )
    }

    /// Reads the package of a block waiting for review where it is in the
    /// Blocks folder, as `inspect` does.
    public func reviewSummary(_ id: BlockID) throws -> BlockPackageSummary {
        guard let placeholder = pendingBlock(id.rawValue) else { throw BlockInstallError.nothingToApprove(id.rawValue) }
        return try inspect(placeholder.packageURL)
    }

    /// Copies the package into the Blocks folder, approves that build and
    /// registers its stand-in, in one step: confirming the sheet is the
    /// owner's approval. The copy goes where the package with this id is,
    /// or to `<blocksRoot>/<id>.topblock` for a new id. For an installed id
    /// this is an update: the folder is replaced in one step and the
    /// existing stand-in takes the new package, keeping its place, settings
    /// and data. A package refused at launch, or waiting for review, is
    /// replaced by the new one, in its place. A refused package, an id
    /// another block already has, a copy that fails, or a package that is
    /// no longer the build with `expectedHash`, changes nothing. A new block
    /// is turned on, as the sheet says; an update keeps its on/off state.
    public func install(_ url: URL, expectedHash: String) throws {
        let source = BlockSource.installed(from: url.path)
        let manifest = try PackageValidator.load(url, source: source)
        let id = BlockID(rawValue: manifest.id)
        try checkAvailable(manifest.id)
        let previous = approvals.approval(for: id)
        let signer = try checkSignature(url, pinned: previous?.signer)
        let existing = installedBlock(manifest.id)
        let placeholder: (block: any NotchBlock, package: URL)? =
            pendingBlock(manifest.id).map { ($0 as any NotchBlock, $0.packageURL) }
                ?? refusedBlock(manifest.id).map { ($0 as any NotchBlock, $0.packageURL) }
        let destination = existing?.packageURL ?? placeholder?.package
            ?? blocksRoot.appending(path: "\(manifest.id).topblock", directoryHint: .isDirectory)
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
        // The copy is what runs, so its signature is checked too, by the same
        // rule, and must give the same signer: the source may have changed
        // between its check and the copy.
        do throws(BlockInstallError) {
            let copied = try checkSignature(incoming, pinned: previous?.signer)
            guard copied == signer else {
                throw BlockInstallError.badSignature("the package changed while it was copied")
            }
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            log.error("copy of \(url.path, privacy: .public) refused: \(error.errorDescription ?? String(describing: error), privacy: .public)")
            throw error
        }
        // The copy is the build the owner reviewed, or nothing is installed.
        let hash = PackageHash.of(incoming)
        guard hash == expectedHash else {
            try? FileManager.default.removeItem(at: incoming)
            log.error("copy of \(url.path, privacy: .public) refused: not the build that was reviewed")
            throw BlockInstallError.changedDuringReview
        }
        // The copy's build is approved before the swap: the hash does not
        // depend on the folder name, and a failed swap restores the old approval.
        do {
            try record(Approval(id: id, hash: hash, signer: signer, hosts: manifest.hosts, events: manifest.events),
                       failure: "not stored")
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw BlockInstallError.copyFailed(error.localizedDescription)
        }

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
            restore(previous, of: id)
            if let existing, let old { existing.replacePackage(manifest: old.0, source: old.1) }
            log.error("install of \(manifest.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw BlockInstallError.copyFailed(error.localizedDescription)
        }
        defaults.set(url.path, forKey: Self.installedFromKey(manifest.id))

        if let existing {
            log.info("updated \(manifest.id, privacy: .public) to \(manifest.version, privacy: .public)")
            startingVerified(existing) { existing.replacePackage(manifest: manifest, source: source) }
        } else {
            log.info("installed \(manifest.id, privacy: .public) \(manifest.version, privacy: .public) from \(url.path, privacy: .public)")
            let block = standIn(manifest: manifest, package: destination, source: source)
            made.append(block)
            startingVerified(block) {
                if let placeholder {
                    forget(placeholder.block)
                    replace(block)
                } else {
                    register(block)
                }
                turnOn(id)
            }
        }
    }

    /// Checks the package of a block waiting for review again, its signer
    /// against the one approved before if any, records the approval of this
    /// build (hash, signer, hosts), and puts the block's stand-in in the
    /// placeholder's place and turns it on. The package stays where it was
    /// found. A package that is no longer the build with `expectedHash`, the
    /// one the owner reviewed, is refused with `changedDuringReview`.
    public func approve(_ id: BlockID, expectedHash: String) throws {
        guard let placeholder = pendingBlock(id.rawValue) else { throw BlockInstallError.nothingToApprove(id.rawValue) }
        let package = placeholder.packageURL
        let source = placeholder.info.source
        // Hashed before the checks and again after: the build recorded is the one checked.
        let hash = PackageHash.of(package)
        guard hash == expectedHash else { throw BlockInstallError.changedDuringReview }
        let manifest = try PackageValidator.load(package, source: source)
        guard manifest.id == id.rawValue else {
            throw BlockInstallError.differentBlock(expected: id.rawValue, found: manifest.id)
        }
        let signer = try checkSignature(package, pinned: approvals.approval(for: id)?.signer)
        guard PackageHash.of(package) == hash else {
            throw BlockInstallError.badSignature("the package changed while it was checked")
        }
        do {
            try record(Approval(id: id, hash: hash, signer: signer, hosts: manifest.hosts, events: manifest.events),
                       failure: "not stored")
        } catch {
            throw BlockInstallError.copyFailed(error.localizedDescription)
        }
        log.info("approved \(id.rawValue, privacy: .public) \(manifest.version, privacy: .public) at \(package.path, privacy: .public)")
        forget(placeholder)
        let block = standIn(manifest: manifest, package: package, source: source)
        made.append(block)
        startingVerified(block) {
            replace(block)
            turnOn(id)
        }
    }

    /// Stops and unregisters an installed block, or one refused at launch or
    /// waiting for review, then deletes its package, its data folder, its
    /// settings keys and its approval.
    public func remove(_ id: BlockID) throws {
        let package: URL
        if let block = installedBlock(id.rawValue) {
            block.stop()
            made.removeAll { $0 === block }
            package = block.packageURL
        } else if let placeholder = refusedBlock(id.rawValue) {
            forget(placeholder)
            package = placeholder.packageURL
        } else if let placeholder = pendingBlock(id.rawValue) {
            forget(placeholder)
            package = placeholder.packageURL
        } else {
            throw BlockInstallError.notRemovable(id.rawValue)
        }
        unregister(id)
        clearKeys(id)
        // Explicit: `clearKeys` is a no-op when the settings have no domain.
        defaults.removeObject(forKey: Self.signerKey(id.rawValue))
        do {
            try approvals.remove(id: id)
        } catch {
            // Left behind, it approves only this exact build if it is installed again.
            log.error("approval of \(id.rawValue, privacy: .public) not removed: \(error.localizedDescription, privacy: .public)")
        }
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

    public var blocksFolder: URL? { blocksRoot }

    public func canRemove(_ id: BlockID) -> Bool {
        installedBlock(id.rawValue) != nil || refusedBlock(id.rawValue) != nil || pendingBlock(id.rawValue) != nil
    }

    /// False for an installed package refused at launch or waiting for
    /// review: it cannot start until it is replaced or approved.
    public func canTurnOn(_ id: BlockID) -> Bool {
        refusedBlock(id.rawValue) == nil && pendingBlock(id.rawValue) == nil
    }

    // MARK: Approval

    /// Puts `previous` back as the approval of `id`, or none, after a failed install.
    private func restore(_ previous: Approval?, of id: BlockID) {
        if let previous {
            try? record(previous, failure: "not restored")
            return
        }
        do {
            try approvals.remove(id: id)
        } catch {
            log.error("approval of \(id.rawValue, privacy: .public) not restored: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stores `approval`. A failure is logged as "approval of <id> <failure>"
    /// and thrown, for the caller to handle its own way.
    private func record(_ approval: Approval, failure: String) throws {
        do {
            try approvals.approve(id: approval.id, hash: approval.hash, signer: approval.signer,
                                  hosts: approval.hosts, events: approval.events)
        } catch {
            log.error("approval of \(approval.id.rawValue, privacy: .public) \(failure, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Runs `start`, which starts `block` right after its package was hashed
    /// against its approval, with that start's check passing without a second hash.
    private func startingVerified(_ block: RemoteBlock, _ start: () -> Void) {
        justVerified.insert(ObjectIdentifier(block))
        start()
        justVerified.remove(ObjectIdentifier(block))
    }

    /// The approval of an installed block from a version before approvals:
    /// its signer in the preferences (`signerKey`) and no approval. When the
    /// package is still signed by that signer, its build as it is now is
    /// approved once, so the owner's block keeps running, and the
    /// preference is deleted. Nil without that preference, or when the
    /// approval cannot be stored: the block then waits for review.
    /// - Throws: the signature refusal, as before approvals.
    private func migratedApproval(_ id: String, manifest: Manifest, package: URL) throws(BlockInstallError) -> Approval? {
        guard let signer = defaults.string(forKey: Self.signerKey(id)) else { return nil }
        _ = try checkSignature(package, pinned: signer)
        let approval = Approval(id: BlockID(rawValue: id), hash: PackageHash.of(package), signer: signer,
                                hosts: manifest.hosts, events: manifest.events)
        do {
            try record(approval, failure: "from its stored signer not stored")
        } catch {
            return nil
        }
        defaults.removeObject(forKey: Self.signerKey(id))
        log.info("installed block \(id, privacy: .public) approved once as an earlier version installed it, signed by \(signer, privacy: .public)")
        return approval
    }

    /// Hashes an installed block's package again before each start of its
    /// process, at launch, when it is turned on and before a restart after a
    /// failure (D18). A package that is no longer the approved build is not
    /// started: its stand-in is replaced by a `PendingBlock` (changed),
    /// which turns it off. Returns the reason the start is refused, or nil.
    private func recheck(_ block: RemoteBlock) -> String? {
        guard made.contains(where: { $0 === block }) else { return nil }
        // Hashed moments ago, before this start: see `justVerified`.
        if justVerified.remove(ObjectIdentifier(block)) != nil { return nil }
        guard approvals.approval(for: block.id)?.hash != PackageHash.of(block.packageURL) else { return nil }
        log.error("installed block \(block.id.rawValue, privacy: .public) not started: its package changed after it was approved")
        made.removeAll { $0 === block }
        let placeholder = PendingBlock(manifest: block.manifest, packageURL: block.packageURL, source: block.source, reason: .changed)
        pending.append(placeholder)
        replace(placeholder)
        return PendingBlock.reason(.changed)
    }

    // MARK: Signature

    /// The rule for an installed package, at install, approval and every
    /// launch: a valid signature by `pinned`, the signer approved before,
    /// if there is one. An unsigned or ad hoc package passes, as the owner
    /// approves its exact build, but never as an update of a signed block.
    /// A broken seal never passes. Bundled blocks are covered by the app's
    /// own seal and development blocks have no rule; neither comes through here.
    /// - Returns: the signer to record, or nil for an unsigned or ad hoc package.
    private func checkSignature(_ package: URL, pinned: String?) throws(BlockInstallError) -> String? {
        switch signatures.check(package) {
        case let .invalid(reason):
            throw .badSignature(reason)
        case let .valid(signer, teamID):
            let name = Self.signerName(signer: signer, teamID: teamID)
            if let pinned, pinned != name { throw .differentSigner(installed: pinned, found: name) }
            return name
        case .adHoc, .unsigned:
            if let pinned { throw .differentSigner(installed: pinned, found: "no signature") }
            return nil
        }
    }

    /// The signer as shown and stored: the certificate's name, with the
    /// team id when the name does not already carry it.
    nonisolated static func signerName(signer: String, teamID: String) -> String {
        teamID.isEmpty || signer.contains(teamID) ? signer : "\(signer) (\(teamID))"
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

    /// The placeholder of an installed package waiting for review, if any.
    private func pendingBlock(_ id: String) -> PendingBlock? {
        pending.first { $0.id.rawValue == id }
    }

    /// Drops a placeholder from this store's lists, before it is replaced or removed.
    private func forget(_ placeholder: any NotchBlock) {
        refused.removeAll { $0 === placeholder }
        pending.removeAll { $0 === placeholder }
    }

    /// True when this store already has a stand-in or placeholder with this id.
    private func isHeld(_ id: String) -> Bool {
        made.contains { $0.id.rawValue == id } || refusedBlock(id) != nil || pendingBlock(id) != nil
    }

    /// Refuses an id that a bundled or development block, or a block outside
    /// this store, already has. An installed id passes: installing it updates.
    private func checkAvailable(_ id: String) throws(BlockInstallError) {
        if installedBlock(id) != nil || refusedBlock(id) != nil || pendingBlock(id) != nil { return }
        if isHeld(id) || isRegistered(BlockID(rawValue: id)) { throw .idInUse(id) }
    }

    /// Every `.topblock` folder in `bundledRoot`, sorted by name.
    private func bundledBlocks() -> [RemoteBlock] {
        guard let bundledRoot else { return [] }
        return packages(in: bundledRoot, kind: "bundled")
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { block(at: $0, source: .bundled, kind: "bundled") }
    }

    /// A package found in `blocksRoot`, with its manifest as read.
    private struct Found {
        let package: URL
        /// The manifest's id, or the folder name when the manifest does not decode.
        let id: String
        let read: Result<Manifest, BlockInstallError>
        var decoded: Manifest? { try? read.get() }
    }

    /// Every `.topblock` folder in `blocksRoot`, under any folder name, sorted
    /// by id; the id comes from the manifest (D27). Each becomes a stand-in
    /// when its build is approved, a `PendingBlock` when it is not, and a
    /// `RefusedBlock` when the validator or the signature check refuses it.
    /// Of several packages with one id, the approved build is kept, else the
    /// folder named `<id>.topblock`, else the first by folder name; each
    /// other one is a `RefusedBlock` with the reason. A package whose id is
    /// not a valid one is logged and left out: Remove could clear other keys.
    private func installedBlocks() -> [any NotchBlock] {
        let found = packages(in: blocksRoot, kind: "installed").compactMap { package -> Found? in
            let read = Result { () throws(BlockInstallError) in try PackageValidator.read(package) }
            let id = (try? read.get())?.id ?? package.deletingPathExtension().lastPathComponent
            do {
                try PackageValidator.checkID(id, source: .installed(from: package.path))
            } catch {
                log.error("installed block at \(package.path, privacy: .public) skipped: \(id, privacy: .public) is not a block id")
                return nil
            }
            return Found(package: package, id: id, read: read)
        }
        var blocks: [any NotchBlock] = []
        for group in Dictionary(grouping: found, by: \.id).values {
            let ordered = group.count == 1 ? group : preferred(group)
            guard let kept = ordered.first else { continue }
            blocks.append(installedStandIn(kept))
            blocks += ordered.dropFirst().map { duplicate($0, of: kept) }
        }
        return blocks.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Packages with one id, the one to keep first: see `installedBlocks`.
    private func preferred(_ group: [Found]) -> [Found] {
        let approved = group.first.flatMap { approvals.approval(for: BlockID(rawValue: $0.id))?.hash }
        let keyed = group.map { found -> (key: (Int, Int, String), found: Found) in
            let name = found.package.deletingPathExtension().lastPathComponent
            let isApproved = approved != nil && PackageHash.of(found.package) == approved
            return ((isApproved ? 0 : 1, name == found.id ? 0 : 1, name), found)
        }
        return keyed.sorted { $0.key < $1.key }.map(\.found)
    }

    /// The stand-in, `PendingBlock` or `RefusedBlock` for one installed package.
    private func installedStandIn(_ found: Found) -> any NotchBlock {
        let (package, id) = (found.package, found.id)
        // The original path is shown on the Blocks page; the copy is what runs.
        let from = defaults.string(forKey: Self.installedFromKey(id)) ?? package.path
        let source = BlockSource.installed(from: from)
        do throws(BlockInstallError) {
            let manifest = try found.read.get()
            try PackageValidator.validate(manifest, package: package, source: source)
            // Checked again at every launch: a package changed on disk does not run.
            // Synchronous on the main actor: milliseconds for a few blocks. Move
            // the checks off the main actor, in parallel, once installed blocks
            // number in the dozens.
            var approval = approvals.approval(for: BlockID(rawValue: id))
            if approval == nil { approval = try migratedApproval(id, manifest: manifest, package: package) }
            guard let approval, approval.hash == PackageHash.of(package) else {
                // A broken seal is refused, not offered for review.
                _ = try checkSignature(package, pinned: nil)
                let review: BlockReview = approval == nil ? .new : .changed
                log.info("installed block \(id, privacy: .public) waits for review (\(review == .new ? "new" : "changed", privacy: .public)) at \(package.path, privacy: .public)")
                return PendingBlock(manifest: manifest, packageURL: package, source: source, reason: review)
            }
            _ = try checkSignature(package, pinned: approval.signer)
            log.info("installed block \(id, privacy: .public) \(manifest.version, privacy: .public) from \(package.path, privacy: .public)")
            let block = standIn(manifest: manifest, package: package, source: source)
            // Just hashed: its first start, when the app registers it, does not hash again.
            justVerified.insert(ObjectIdentifier(block))
            return block
        } catch {
            let reason = error.errorDescription ?? String(describing: error)
            log.error("installed block \(id, privacy: .public) turned off: \(reason, privacy: .public)")
            return RefusedBlock(id: BlockID(rawValue: id), title: found.decoded?.name ?? id,
                                packageURL: package, source: source, reason: reason)
        }
    }

    /// A second package with an id another package in the Blocks folder
    /// has, listed refused so it can be removed. Its id is the block id and
    /// the folder name, which no manifest can have, so it never takes the
    /// other's place, settings or data.
    private func duplicate(_ found: Found, of kept: Found) -> RefusedBlock {
        let folder = found.package.lastPathComponent
        let reason = "Another package in the Blocks folder, \"\(kept.package.lastPathComponent)\", already has the id \"\(found.id)\", so this one does not run. Remove this copy, or remove the other one first."
        log.error("installed block at \(found.package.path, privacy: .public) turned off: its id \(found.id, privacy: .public) is taken")
        return RefusedBlock(id: BlockID(rawValue: "\(found.id)@\(folder)"), title: found.decoded?.name ?? found.id,
                            packageURL: found.package, source: .installed(from: found.package.path), reason: reason)
    }

    /// Each package as `folder/<name>`, in `folder`'s form, as install forms
    /// its destination: `contentsOfDirectory(at:)` returns paths with
    /// symbolic links resolved (`/private/var/...` for `/var/...`).
    private func packages(in folder: URL, kind: String) -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { ($0 as NSString).pathExtension == "topblock" }
                .map { folder.appending(path: $0, directoryHint: .isDirectory) }
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

    /// Why an installed block does not start when its store is gone.
    static let uncheckedReason = "TopNotch could not check this block's package."

    private func standIn(manifest: Manifest, package: URL, source: BlockSource) -> RemoteBlock {
        let block = RemoteBlock(
            manifest: manifest,
            packageURL: package,
            source: source,
            dataFolder: dataRoot.appending(path: manifest.id),
            owner: owner,
            launcher: launcher,
            screenshotFolder: screenshotFolder,
            defaults: defaults,
            turnOff: turnOff
        )
        if case .installed = source {
            // Before every start: still the approved build?
            block.startCheck = { [weak self, weak block] in
                guard let block else { return nil }
                // No store, no hash: fail closed rather than start unchecked.
                guard let self else { return Self.uncheckedReason }
                return self.recheck(block)
            }
        }
        return block
    }
}
