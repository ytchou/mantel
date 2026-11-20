import BlockWire
import Foundation
import NotchCore
import os

/// Finds block packages and makes their stand-ins. The app makes one call to
/// get the stand-ins, registers them, and calls `stopAll()` when it quits.
///
/// For now it knows only the development block: one package run from where
/// it is, named with the `-devBlock <path>` launch argument. Bundled and
/// installed packages come later.
@MainActor
public final class BlockStore {
    private let owner: @MainActor () -> BlockID?
    private let dataRoot: URL
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
    ///   - defaults: where block settings and turn-off reasons are stored.
    ///   - turnOff: turns a block off after repeated failures; the app passes
    ///     a closure that calls `BlockSettings.setEnabled(id, false, in:)`.
    public init(
        owner: @escaping @MainActor () -> BlockID?,
        dataRoot: URL = BlockStore.defaultDataRoot,
        launcher: @escaping BlockLauncher = { try BlockProcess.spawn(executable: $0, generation: $1) },
        defaults: UserDefaults = .standard,
        turnOff: @escaping @MainActor (BlockID) -> Void = { _ in }
    ) {
        self.owner = owner
        self.dataRoot = dataRoot
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

    /// The stand-ins to register, in order. `developmentPath` is a
    /// `.topblock` folder to run from where it is; a missing one, or one
    /// `PackageValidator` refuses, is logged and left out.
    public func standIns(developmentPath: String?) -> [RemoteBlock] {
        guard let developmentPath, let block = developmentBlock(at: developmentPath) else { return [] }
        made.append(block)
        return [block]
    }

    /// Ends every block process this store started and waits for each to exit.
    public func stopAll() {
        for block in made { block.stop() }
    }

    private func developmentBlock(at path: String) -> RemoteBlock? {
        let package = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let manifest: Manifest
        do {
            manifest = try PackageValidator.load(package, source: .development(path: package.path))
        } catch {
            log.error("development block at \(package.path, privacy: .public) not loaded: \(error.errorDescription ?? String(describing: error), privacy: .public)")
            return nil
        }
        log.info("development block \(manifest.id, privacy: .public) \(manifest.version, privacy: .public) from \(package.path, privacy: .public)")
        return RemoteBlock(
            manifest: manifest,
            packageURL: package,
            source: .development(path: package.path),
            dataFolder: dataRoot.appending(path: manifest.id),
            owner: owner,
            launcher: launcher,
            defaults: defaults,
            turnOff: turnOff
        )
    }
}
