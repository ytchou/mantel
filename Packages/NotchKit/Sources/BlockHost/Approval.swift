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
    static func of(_ package: URL) -> String {
        let manager = FileManager.default
        // `subpaths(atPath:)` does not follow symbolic links. A missing
        // package hashes as an empty one, which matches no approval.
        let paths = (manager.subpaths(atPath: package.path) ?? []).sorted()
        var hasher = SHA256()
        for path in paths {
            let item = package.appending(path: path).path
            guard let type = (try? manager.attributesOfItem(atPath: item))?[.type] as? FileAttributeType else {
                add(kind: "?", path: path, content: Data(), to: &hasher)
                continue
            }
            switch type {
            case .typeRegular:
                // Whole file in memory: packages are a few MB. Stream in
                // chunks if packages grow past ~100 MB.
                if let content = manager.contents(atPath: item) {
                    add(kind: "F", path: path, content: content, to: &hasher)
                } else {
                    add(kind: "?", path: path, content: Data(), to: &hasher)
                }
            case .typeSymbolicLink:
                let target = (try? manager.destinationOfSymbolicLink(atPath: item)) ?? ""
                add(kind: "L", path: path, content: Data(target.utf8), to: &hasher)
            default:
                continue
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
/// the signer then (nil for an unsigned package) and the hosts approved.
struct Approval: Equatable, Sendable {
    let id: BlockID
    let hash: String
    let signer: String?
    let hosts: [String]
}

/// Approvals kept in a small JSON file, not in the preferences, so a block
/// cannot read or change them (D18). The app's file is
/// `<support root>/Approvals.json`, beside `Blocks/` and `BlockData/`;
/// `BlockStore` passes it in.
///
/// Each call reads the file again, and each change rewrites it atomically.
/// A missing or damaged file reads as no approvals.
struct ApprovalStore: Sendable {
    let file: URL

    init(file: URL) {
        self.file = file
    }

    func approval(for id: BlockID) -> Approval? {
        records()[id.rawValue].map {
            Approval(id: id, hash: $0.hash, signer: $0.signer, hosts: $0.hosts)
        }
    }

    func approve(id: BlockID, hash: String, signer: String?, hosts: [String]) throws {
        var all = records()
        all[id.rawValue] = Record(hash: hash, signer: signer, hosts: hosts)
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
