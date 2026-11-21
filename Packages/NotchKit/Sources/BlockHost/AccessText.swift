import BlockWire

extension Access {
    /// The access in the user's words, for the install sheet and the Blocks page.
    var displayText: String {
        switch self {
        case .network: "Use the network"
        case .filesRead: "Read your files"
        case .filesScreenshots: "Rename files in the screenshot folder"
        }
    }
}

extension Manifest {
    /// What the block may do from inside its sandbox, in the user's words.
    /// The one place this text is made: `BlockStore` shows it on the install
    /// sheet, `RemoteBlock` on the Blocks page after the author's permissions.
    var accessText: [String] { access.map(\.displayText) }
}
