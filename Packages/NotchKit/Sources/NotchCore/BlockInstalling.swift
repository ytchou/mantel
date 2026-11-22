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
    /// an installed block with the same id. `expectedHash` is the
    /// `packageHash` of the summary the owner confirmed: a package that is
    /// no longer that build is refused with `changedDuringReview`.
    func install(_ url: URL, expectedHash: String) throws

    /// Approve the package of a block waiting for review, found in the
    /// Blocks folder or changed since its last approval, and start it.
    /// Checks the package again first and throws the refusal the user would
    /// see on install. `expectedHash` binds the approval to the build the
    /// owner reviewed, as for `install`.
    func approve(_ id: BlockID, expectedHash: String) throws

    /// Read the package of a block waiting for review, where it is, as
    /// `inspect` reads a chosen one, for the sheet that approves it. Throws
    /// `nothingToApprove` when no block with this id waits.
    func reviewSummary(_ id: BlockID) throws -> BlockPackageSummary

    /// Stop the block and delete its package, data folder, settings and approval.
    func remove(_ id: BlockID) throws

    /// True only for blocks the user installed.
    func canRemove(_ id: BlockID) -> Bool

    /// False for a block that cannot start whatever the user does, such as an
    /// installed package refused at launch; the Blocks page then offers no
    /// "Turn On". True by default.
    func canTurnOn(_ id: BlockID) -> Bool

    /// The folder installed packages are kept in, shown on the Blocks page.
    /// Nil by default: no folder is shown.
    var blocksFolder: URL? { get }
}

public extension BlockInstalling {
    func canTurnOn(_ id: BlockID) -> Bool { true }
    var blocksFolder: URL? { nil }
    func reviewSummary(_ id: BlockID) throws -> BlockPackageSummary { throw BlockInstallError.nothingToApprove(id.rawValue) }
}

/// Access that together lets a block read the owner's files and send them
/// away: `network` with `files.read` or `files.screenshots` (D17).
/// `network` alone is not one.
public enum RiskyPair: Sendable, Equatable {
    /// `network` with `files.read`.
    case files
    /// `network` with `files.screenshots`, without `files.read`.
    case screenshots
}

/// What a package says about itself, shown before the user confirms an install.
public struct BlockPackageSummary: Sendable, Equatable {
    public var id: BlockID
    public var name: String
    public var version: String
    /// The contract version the package was built for.
    public var contract: Int
    /// The SHA-256 of the package as read for this summary. Confirming the
    /// sheet passes it back, so only this build is installed or approved.
    public var packageHash: String
    /// Events the installed or approved version did not listen to. Empty for
    /// a new install.
    public var newEvents: [String]
    /// What each event the block listens to reveals and needs, in the
    /// manifest's order.
    public var eventEntries: [EventEntry]
    /// What the block needs from the system, in the user's words.
    public var permissions: [String]
    /// Path of the package being inspected.
    public var sourcePath: String
    /// Version already installed, or `nil` when the block is not installed.
    public var installedVersion: String?
    /// What the block may do from inside its sandbox, in the user's words,
    /// such as "Use the network". Empty for the default profile.
    public var access: [String]
    /// Who signed the package, such as a developer name or team. `nil` when
    /// it is not signed or signed ad hoc.
    public var signer: String?
    /// True when the package has a valid signature that is not ad hoc.
    /// False for an unsigned or ad hoc package: its creator cannot be verified.
    public var isSigned: Bool { signer != nil }
    /// The hosts the block may reach, in the manifest's order. Empty without `network`.
    public var hosts: [String]
    /// Hosts the installed or approved version could not reach. Empty for a new install.
    public var newHosts: [String]
    /// Set when the block's access lets it read files and send them away.
    public var riskyPair: RiskyPair?

    public init(
        id: BlockID,
        name: String,
        version: String,
        contract: Int,
        packageHash: String = "",
        newEvents: [String] = [],
        eventEntries: [EventEntry] = [],
        permissions: [String] = [],
        sourcePath: String,
        installedVersion: String? = nil,
        access: [String] = [],
        signer: String? = nil,
        hosts: [String] = [],
        newHosts: [String] = [],
        riskyPair: RiskyPair? = nil
    ) {
        self.hosts = hosts
        self.newHosts = newHosts
        self.riskyPair = riskyPair
        self.id = id
        self.name = name
        self.version = version
        self.contract = contract
        self.packageHash = packageHash
        self.newEvents = newEvents
        self.eventEntries = eventEntries
        self.permissions = permissions
        self.sourcePath = sourcePath
        self.installedVersion = installedVersion
        self.access = access
        self.signer = signer
    }
}

/// Why a package was refused. Each message tells the user what to do next.
public enum BlockInstallError: LocalizedError, Equatable {
    /// The package was built for a contract version this app does not run.
    case unsupportedContract(found: Int, supported: ClosedRange<Int>)
    /// The id is reserved by the app.
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
    /// The block is built in or run as the development block, so it cannot be removed.
    case notRemovable(String)
    /// Copying or deleting files failed.
    case copyFailed(String)
    /// Another block with this id is already running, such as the development block.
    case idInUse(String)
    /// The package chosen to update one block is a different block.
    case differentBlock(expected: String, found: String)
    /// The package's signature is broken: it was changed after signing.
    case badSignature(String)
    /// The update is signed by someone other than the installed block.
    case differentSigner(installed: String, found: String)
    /// The package is in the old flat format, from before blocks were bundles.
    case oldPackageFormat
    /// The manifest asks for access this version of TopNotch does not know.
    case unknownAccess(String)
    /// The manifest asks for `network` but names no `hosts`.
    case networkWithoutHosts
    /// The manifest's `hosts` cannot be used; the detail says why, such as
    /// a bare `*`, or hosts without `network`.
    case invalidHosts(String)
    /// No block with this id waits for review.
    case nothingToApprove(String)
    /// The package is no longer the build the sheet showed.
    case changedDuringReview

    public var errorDescription: String? {
        switch self {
        case let .unsupportedContract(found, supported):
            let supportedText = supported.lowerBound == supported.upperBound
                ? "supports contract \(supported.lowerBound)"
                : "supports contracts \(supported.lowerBound) to \(supported.upperBound)"
            return "This block was built for contract \(found), but this version of TopNotch \(supportedText). Ask the block's author for a matching version, or update TopNotch."
        case let .reservedID(id):
            return "The block id \"\(id)\" is reserved by TopNotch. Ask the block's author to choose a different id."
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
        case let .badSignature(detail):
            return "The block's signature is not valid (\(detail)). The package may have been changed after it was signed. Ask the block's author for a new copy."
        case let .differentSigner(installed, found):
            return "This update is signed by \"\(found)\", but the installed block is signed by \"\(installed)\", so it was not installed. Get the update from the block's original author, or remove the block first if you trust the new signer."
        case .oldPackageFormat:
            return "This block uses the old package format, which this version of TopNotch no longer runs. Ask the block's author to package it again with the current package-block.sh."
        case let .unknownAccess(token):
            return "The block asks for access \"\(token)\", which this version of TopNotch does not know. Update TopNotch, or ask the block's author for a matching version."
        case .networkWithoutHosts:
            return "The block asks to use the network but does not name the hosts it reaches, so TopNotch cannot limit it. Ask the block's author to list its hosts in the manifest."
        case let .invalidHosts(detail):
            return "The block's list of hosts cannot be used: \(detail). Ask the block's author to fix the manifest."
        case let .nothingToApprove(id):
            return "No block \"\(id)\" is waiting for review. Open the Blocks page again to see its current state."
        case .changedDuringReview:
            return "The package changed while you were reviewing it. Review it again."
        }
    }
}
