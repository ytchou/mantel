import Foundation
import NotchCore

/// Stands in for an installed package that `PackageValidator` refused at
/// launch, such as one built for a contract this app no longer runs. It is
/// listed on the Blocks page, turned off with the reason, so the user can
/// see why and remove it. It never runs anything.
@MainActor
final class RefusedBlock: NotchBlock {
    let id: BlockID
    let title: String
    let info: BlockInfo
    let health: BlockHealth
    /// The installed `<id>.topblock` folder, deleted by Remove.
    let packageURL: URL

    /// - Parameters:
    ///   - title: the manifest's name when it decodes, otherwise the id.
    ///   - reason: the refusal, in the user's words.
    init(id: BlockID, title: String, packageURL: URL, source: BlockSource, reason: String) {
        self.id = id
        self.title = title
        self.packageURL = packageURL
        info = BlockInfo(source: source)
        health = .turnedOff(reason: reason)
    }

    func activate(_ context: any BlockContext) {}
}
