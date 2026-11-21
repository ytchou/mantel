import CryptoKit
import Foundation
import NotchCore

/// The SHA-256 of a block package's contents, recorded when the owner
/// approves the package and compared before every start (D18).
enum PackageHash {
    /// A lowercase hex SHA-256 over every regular file and symbolic link in
    /// `package`, in sorted order of their paths relative to `package`. Each
    /// entry adds a kind byte, the path's length and bytes, then the
    /// content's length and bytes; a link's content is its target text, not
    /// what it points to. Lengths are 8-byte big-endian, so no two packages
    /// share an input. The folder's own name and the file dates are not
    /// part of it. Folders add nothing on their own, and other kinds of
    /// item (sockets, pipes) are skipped: a package holds neither.
    ///
    /// Fails closed: when the package is missing, or any item in it cannot be
    /// read (a file that cannot be opened, a folder that cannot be listed),
    /// the result is `unreadable` followed by a new random value, which is
    /// not hex, matches no approval and differs from every earlier result.
    /// A package the app cannot read in full is never taken as approved.
    static func of(_ package: URL) -> String {
        let manager = FileManager.default
        // `subpaths(atPath:)` does not follow symbolic links.
        guard let listed = manager.subpaths(atPath: package.path) else { return unreadable() }
        var hasher = SHA256()
        for path in listed.sorted() {
            let item = package.appending(path: path).path
            guard let type = (try? manager.attributesOfItem(atPath: item))?[.type] as? FileAttributeType else {
                return unreadable()
            }
            switch type {
            case .typeRegular:
                // Whole file in memory: packages are a few MB. Stream in
                // chunks if packages grow past ~100 MB.
                guard let content = manager.contents(atPath: item) else { return unreadable() }
                add(kind: "F", path: path, content: content, to: &hasher)
            case .typeSymbolicLink:
                guard let target = try? manager.destinationOfSymbolicLink(atPath: item) else { return unreadable() }
                add(kind: "L", path: path, content: Data(target.utf8), to: &hasher)
            case .typeDirectory:
                // `subpaths` skips a folder it cannot list without saying so.
                guard (try? manager.contentsOfDirectory(atPath: item)) != nil else { return unreadable() }
            default:
                continue
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A value no approval holds and no later call returns again.
    private static func unreadable() -> String {
        "unreadable-\(UUID().uuidString)"
    }

    private static func add(kind: Character, path: String, content: Data, to hasher: inout SHA256) {
        hasher.update(data: Data(kind.utf8))
        let pathBytes = Data(path.utf8)
        hasher.update(data: length(pathBytes.count))
        hasher.update(data: pathBytes)
        hasher.update(data: length(content.count))
        hasher.update(data: content)
    }

    private static func length(_ count: Int) -> Data {
        withUnsafeBytes(of: UInt64(count).bigEndian) { Data($0) }
    }
}

/// The owner's approval of one block package: the package hash at the time,
/// the signer then (nil for an unsigned package), the hosts approved and the
/// events the package listened to then.
struct Approval: Equatable, Sendable {
    let id: BlockID
    let hash: String
    let signer: String?
    let hosts: [String]
    /// Empty for an approval stored before events were kept.
    var events: [String] = []
}

/// Approvals kept in a small JSON file, not in the preferences, so a block
/// cannot read or change them (D18). The app's file is
/// `<support root>/Approvals.json`, beside `Blocks/` and `BlockData/`;
/// `BlockStore` passes it in.
///
/// Each call reads the file again, and each change rewrites it atomically.
/// A missing or damaged file reads as no approvals.
// Re-reading on every call is a deliberate shortcut: the file is a few KB,
// read a few times per block start, so it stays cheap for tens of blocks and
// is never stale. Upgrade path if starts or blocks grow by an order of
// magnitude: keep the records in memory, filled on first read and replaced
// on every write.
struct ApprovalStore: Sendable {
    let file: URL

    init(file: URL) {
        self.file = file
    }

    func approval(for id: BlockID) -> Approval? {
        records()[id.rawValue].map {
            Approval(id: id, hash: $0.hash, signer: $0.signer, hosts: $0.hosts, events: $0.events)
        }
    }

    func approve(id: BlockID, hash: String, signer: String?, hosts: [String], events: [String] = []) throws {
        var all = records()
        all[id.rawValue] = Record(hash: hash, signer: signer, hosts: hosts, events: events)
        try write(all)
    }

    func remove(id: BlockID) throws {
        var all = records()
        guard all.removeValue(forKey: id.rawValue) != nil else { return }
        try write(all)
    }

    // MARK: - File

    /// One approval as stored, keyed by block id in the file.
    private struct Record: Codable {
        let hash: String
        let signer: String?
        let hosts: [String]
        let events: [String]

        init(hash: String, signer: String?, hosts: [String], events: [String]) {
            self.hash = hash
            self.signer = signer
            self.hosts = hosts
            self.events = events
        }

        /// A record written before events were kept has none.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hash = try container.decode(String.self, forKey: .hash)
            signer = try container.decodeIfPresent(String.self, forKey: .signer)
            hosts = try container.decode([String].self, forKey: .hosts)
            events = try container.decodeIfPresent([String].self, forKey: .events) ?? []
        }
    }

    private func records() -> [String: Record] {
        guard let data = try? Data(contentsOf: file),
              let all = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return all
    }

    private func write(_ all: [String: Record]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file, options: .atomic)
    }
}
