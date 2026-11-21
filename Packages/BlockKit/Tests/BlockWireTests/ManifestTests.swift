import Foundation
import Testing
@testable import BlockWire

struct ManifestTests {
    private let valid = """
    {
      "id": "hello",
      "name": "Hello",
      "version": "1.0.0",
      "contract": 1,
      "executable": "HelloBlock",
      "summary": "Says hello on hover.",
      "symbol": "hand.wave",
      "trigger": "Pointer hover",
      "permissions": [],
      "events": ["pointerHover"],
      "settings": [
        {"key": "loud", "type": "toggle", "title": "Loud", "default": true},
        {"key": "size", "type": "choice", "title": "Size", "default": "large",
         "options": [{"value": "large", "title": "Large"}, {"value": "small", "title": "Small"}]},
        {"key": "about", "type": "note", "title": "Hover the notch."}
      ]
    }
    """

    private func without(_ field: String) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        object.removeValue(forKey: field)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func manifestDecodesAndValidatesShape() throws {
        let manifest = try Manifest.decode(Data(valid.utf8))
        #expect(manifest.id == "hello")
        #expect(manifest.contract == 1)
        #expect(manifest.executable == "HelloBlock")
        #expect(manifest.events == ["pointerHover"])
        #expect(manifest.settings.map(\.type) == [.toggle, .choice, .note])
        #expect(manifest.settings[0].default == .bool(true))
        #expect(manifest.settings[1].options?.map(\.value) == ["large", "small"])
        #expect(manifest.settings[2].default == nil)

        #expect(throws: ManifestError.missingField("id")) { try Manifest.decode(try without("id")) }
        #expect(throws: ManifestError.missingField("contract")) { try Manifest.decode(try without("contract")) }

        // Optional lists default to empty.
        let minimal = #"{"id":"a","name":"A","version":"1","contract":1,"executable":"A"}"#
        let decoded = try Manifest.decode(Data(minimal.utf8))
        #expect(decoded.events.isEmpty && decoded.settings.isEmpty && decoded.permissions.isEmpty)

        // A wrong type and a broken file are named too.
        let wrongType = #"{"id":"a","name":"A","version":"1","contract":"one","executable":"A"}"#
        #expect(throws: ManifestError.invalidField("contract")) { try Manifest.decode(Data(wrongType.utf8)) }
        #expect(throws: ManifestError.notJSON) { try Manifest.decode(Data("{".utf8)) }
    }

    @Test func manifestAccessDecodesKnownTokensAndRefusesUnknown() throws {
        func manifest(access: String) -> Data {
            Data(#"{"id":"a","name":"A","version":"1","contract":2,"executable":"A","access":\#(access)}"#.utf8)
        }
        let all = try Manifest.decode(manifest(access: #"["network","files.read","files.screenshots"]"#))
        #expect(all.access == [.network, .filesRead, .filesScreenshots])
        #expect(all.access.map(\.rawValue) == ["network", "files.read", "files.screenshots"])

        #expect(throws: ManifestError.invalidField("access")) { try Manifest.decode(manifest(access: #"["network","camera"]"#)) }
        #expect(throws: ManifestError.invalidField("access")) { try Manifest.decode(manifest(access: #""network""#)) }

        // A version 1 manifest has no `access`: an empty list.
        #expect(try Manifest.decode(Data(valid.utf8)).access.isEmpty)
    }

    @Test func aManifestWithHostsRoundTrips() throws {
        let manifest = Manifest(id: "a", name: "A", version: "1", contract: 3, executable: "A",
                                access: [.network], hosts: ["api.example.com", "*.example.org"])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try Manifest.decode(data)
        #expect(decoded == manifest)
        #expect(decoded.hosts == ["api.example.com", "*.example.org"])
    }

    /// A field added later must be written too: with every field set, the
    /// encoded keys are exactly the coding keys.
    @Test func encodingWritesEveryField() throws {
        let manifest = Manifest(id: "a", name: "A", version: "1", contract: 3, executable: "A",
                                summary: "S", symbol: "star", trigger: "T", permissions: ["P"],
                                access: [.network], hosts: ["api.example.com"], events: ["pointerHover"],
                                settings: [SettingSpec(key: "k", type: .toggle, title: "K")])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == Set(Manifest.CodingKeys.allCases.map(\.stringValue)))
    }

    @Test func aVersionTwoManifestDecodesWithNoHosts() throws {
        let v2 = #"{"id":"a","name":"A","version":"1","contract":2,"executable":"A","access":["files.read"]}"#
        let decoded = try Manifest.decode(Data(v2.utf8))
        #expect(decoded.hosts.isEmpty)

        // With no hosts, the key is left out when encoded.
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!encoded.contains("hosts"), "hosts encoded while empty")
    }
}
