import BlockWire
import Foundation
import NotchCore
import os

/// Finds block packages and makes their stand-ins. The app makes one call to
/// get the stand-ins, registers them, and calls `stopAll()` when it quits.
///
/// It knows the bundled blocks, shipped inside the app bundle (now-playing),
/// and the development block: one package run from where it is, named with
/// the `-devBlock <path>` launch argument. Installed packages come later.
@MainActor
public final class BlockStore {
    private let owner: @MainActor () -> BlockID?
    private let dataRoot: URL
    private let bundledRoot: URL?
    private let launcher: BlockLauncher
    private let defaults: UserDefaults
    private let turnOff: @MainActor (BlockID) -> Void
    private let log = Logger(subsystem: "dev.topnotch.TopNotch", category: "blocks")
    /// Every stand-in this store made, so `stopAll` can end their processes.
    private var made: [RemoteBlock] = []

    /// - Parameters:
    ///   - owner: who owns the notch now; pass `{ runtime.state.owner }`.
    ///     Each stand-in observes it to tell its block when it wins or loses the notch.
    ///   - dataRoot: the folder holding one data folder per block.
    ///   - bundledRoot: the folder of `.topblock` packages shipped with the
    ///     app; the app passes `Contents/Resources/Blocks`. Nil for none.
    ///   - defaults: where block settings and turn-off reasons are stored.
    ///   - turnOff: turns a block off after repeated failures; the app passes
    ///     a closure that calls `BlockSettings.setEnabled(id, false, in:)`.
    public init(
        owner: @escaping @MainActor () -> BlockID?,
        dataRoot: URL = BlockStore.defaultDataRoot,
        bundledRoot: URL? = nil,
        launcher: @escaping BlockLauncher = { try BlockProcess.spawn(executable: $0, generation: $1) },
        defaults: UserDefaults = .standard,
        turnOff: @escaping @MainActor (BlockID) -> Void = { _ in }
    ) {
        self.owner = owner
        self.dataRoot = dataRoot
        self.bundledRoot = bundledRoot
        self.launcher = launcher
        self.defaults = defaults
        self.turnOff = turnOff
    }

    /// `~/Library/Application Support/TopNotch/BlockData`.
    public nonisolated static var defaultDataRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "TopNotch/BlockData")
    }

    /// The stand-ins to register, in order: the bundled blocks by folder
    /// name, then the development block. `developmentPath` is a `.topblock`
    /// folder to run from where it is. A package that is missing, or that
    /// `PackageValidator` refuses, is logged and left out.
    public func standIns(developmentPath: String?) -> [RemoteBlock] {
        var blocks = bundledBlocks()
        if let developmentPath, let block = developmentBlock(at: developmentPath) {
            blocks.append(block)
        }
        made += blocks
        return blocks
    }

    /// Ends every block process this store started and waits for each to exit.
    public func stopAll() {
        for block in made { block.stop() }
    }

    /// Every `.topblock` folder in `bundledRoot`, sorted by name.
    private func bundledBlocks() -> [RemoteBlock] {
        guard let bundledRoot else { return [] }
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: bundledRoot, includingPropertiesForKeys: nil)
        } catch {
            log.error("no bundled blocks at \(bundledRoot.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
        return folders
            .filter { $0.pathExtension == "topblock" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { block(at: $0, source: .bundled, kind: "bundled") }
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
        return RemoteBlock(
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
