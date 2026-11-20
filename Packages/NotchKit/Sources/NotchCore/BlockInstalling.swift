import Foundation

/// Installs, updates and removes block packages. The settings window uses it
/// through this protocol, so it never depends on the module that runs blocks.
///
/// Installing a package whose id is already installed updates that block.
@MainActor
public protocol BlockInstalling: AnyObject {
    /// Read and check the package at `url` without installing it. Throws the
    /// refusal the user would see on install.
    func inspect(_ url: URL) throws -> BlockPackageSummary

    /// Copy the package at `url` into the installed blocks and start it. Replaces
    /// an installed block with the same id.
    func install(_ url: URL) throws

    /// Stop the block and delete its package, data folder and settings.
    func remove(_ id: BlockID) throws

    /// True only for blocks the user installed.
    func canRemove(_ id: BlockID) -> Bool

    /// False for a block that cannot start whatever the user does, such as an
    /// installed package refused at launch; the Blocks page then offers no
    /// "Turn On". True by default.
    func canTurnOn(_ id: BlockID) -> Bool
}

public extension BlockInstalling {
    func canTurnOn(_ id: BlockID) -> Bool { true }
}

/// What a package says about itself, shown before the user confirms an install.
public struct BlockPackageSummary: Sendable, Equatable {
    public var id: BlockID
    public var name: String
    public var version: String
    /// The contract version the package was built for.
    public var contract: Int
    /// Events the block listens to, as display text.
    public var events: [String]
    /// Events the installed version did not listen to. Empty for a new install.
    public var newEvents: [String]
    /// What the block needs from the system, in the user's words.
    public var permissions: [String]
    /// Path of the package being inspected.
    public var sourcePath: String
    /// Version already installed, or `nil` when the block is not installed.
    public var installedVersion: String?

    public init(
        id: BlockID,
        name: String,
        version: String,
        contract: Int,
        events: [String] = [],
        newEvents: [String] = [],
        permissions: [String] = [],
        sourcePath: String,
        installedVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.contract = contract
        self.events = events
        self.newEvents = newEvents
        self.permissions = permissions
        self.sourcePath = sourcePath
        self.installedVersion = installedVersion
    }
}

/// Why a package was refused. Each message tells the user what to do next.
public enum BlockInstallError: LocalizedError, Equatable {
    /// The package was built for a contract version this app does not run.
    case unsupportedContract(found: Int, supported: ClosedRange<Int>)
    /// The id belongs to a block built into the app.
    case reservedID(String)
    /// The id is not lowercase letters, digits and hyphens.
    case invalidID(String)
    /// The executable path leads outside the package.
    case executableOutsidePackage(String)
    /// The executable is missing or cannot be run.
    case executableMissing(String)
    /// The manifest names an event the app does not know.
    case unknownEvent(String)
    /// A setting in the manifest is malformed.
    case invalidSetting(String)
    /// `manifest.json` is missing or cannot be read.
    case unreadableManifest(String)
    /// The block is built in or bundled, so it cannot be removed.
    case notRemovable(String)
    /// Copying or deleting files failed.
    case copyFailed(String)
    /// Another block with this id is already running, such as the development block.
    case idInUse(String)
    /// The package chosen to update one block is a different block.
    case differentBlock(expected: String, found: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedContract(found, supported):
            let supportedText = supported.lowerBound == supported.upperBound
                ? "supports contract \(supported.lowerBound)"
                : "supports contracts \(supported.lowerBound) to \(supported.upperBound)"
            return "This block was built for contract \(found), but this version of TopNotch \(supportedText). Ask the block's author for a matching version, or update TopNotch."
        case let .reservedID(id):
            return "The block id \"\(id)\" belongs to a block built into TopNotch. Ask the block's author to choose a different id."
        case let .invalidID(id):
            return "The block id \"\(id)\" is not valid. Ids use only lowercase letters, digits and hyphens. Ask the block's author to fix the id."
        case let .executableOutsidePackage(path):
            return "The block's program \"\(path)\" is outside its package, so it was not installed. Ask the block's author to fix the package."
        case let .executableMissing(path):
            return "The block's program \"\(path)\" is missing or cannot be run. Ask the block's author for a complete package."
        case let .unknownEvent(name):
            return "The block listens to \"\(name)\", which this version of TopNotch does not know. Update TopNotch, or ask the block's author for a matching version."
        case let .invalidSetting(key):
            return "The block's setting \"\(key)\" is not valid. Ask the block's author to fix the package."
        case let .unreadableManifest(detail):
            return "The block's manifest.json could not be read (\(detail)). Check that you chose a .topblock package, or ask the block's author for a new copy."
        case let .notRemovable(id):
            return "The block \"\(id)\" comes with TopNotch and cannot be removed. Turn it off on the Blocks page instead."
        case let .copyFailed(detail):
            return "TopNotch could not copy or delete the block's files (\(detail)). Check that you have free disk space and access to the folder, then try again."
        case let .idInUse(id):
            return "A block with the id \"\(id)\" is already running in TopNotch, for example as the development block. Quit TopNotch and open it without that block, or ask the block's author to choose a different id."
        case let .differentBlock(expected, found):
            return "This package is the block \"\(found)\", not \"\(expected)\", so it cannot update \"\(expected)\". Choose the package of \"\(expected)\", or use Install Block\u{2026} to add \"\(found)\"."
        }
    }
}
