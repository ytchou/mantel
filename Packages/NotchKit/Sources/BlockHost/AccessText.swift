import BlockWire
import NotchCore

extension Access {
    /// The access in the user's words, for the install sheet and the Blocks
    /// page. `network` names the hosts the block may reach.
    func displayText(hosts: [String]) -> String {
        switch self {
        case .network: "Use the network, only to reach: \(hosts.joined(separator: ", "))"
        case .filesRead: "Read your files"
        case .filesScreenshots: "Rename files in the screenshot folder"
        }
    }
}

extension Manifest {
    /// What the block may do from inside its sandbox, in the user's words.
    /// The one place this text is made: `BlockStore` shows it on the install
    /// sheet, `RemoteBlock` on the Blocks page after the author's permissions.
    var accessText: [String] { access.map { $0.displayText(hosts: hosts) } }

    /// The block's row on the Blocks page, the same for a running block
    /// (`RemoteBlock`) and one waiting for review (`PendingBlock`): the
    /// access the sandbox grants, in the user's words, after what the
    /// author wrote.
    func blockInfo(source: BlockSource) -> BlockInfo {
        BlockInfo(summary: summary, symbol: symbol.isEmpty ? "square.grid.2x2" : symbol,
                  trigger: trigger, permissions: permissions + accessText,
                  version: version, source: source)
    }

    /// The access for the install sheet, which lists the hosts on a row of
    /// their own ("Can reach"), so `network` does not repeat them.
    var sheetAccessText: [String] { access.map { $0 == .network ? "Use the network" : $0.displayText(hosts: hosts) } }

    /// `network` with `files.read` or `files.screenshots`, or nil.
    var riskyPair: RiskyPair? {
        guard access.contains(.network) else { return nil }
        if access.contains(.filesRead) { return .files }
        if access.contains(.filesScreenshots) { return .screenshots }
        return nil
    }
}
