import BlockWire
import Foundation
import Testing
@testable import BlockHost

/// The real `FixtureBlock` executable over a real socket pair.
@Suite(.serialized)
struct ProcessTests {
    @Test func spawnedFixtureSaysHello() async throws {
        let package = try Fixture.package()
        let process = try BlockProcess.spawn(executable: package.appending(path: "FixtureBlock"), generation: 7)
        defer { process.terminate() }

        var hello: Envelope<BlockToHost>?
        for try await envelope in process.envelopes(of: BlockToHost.self) {
            hello = envelope
            break
        }

        let first = try #require(hello)
        #expect(first.generation == 7, "the generation comes from TOPNOTCH_BLOCK_GENERATION")
        #expect(first.message == .hello(contract: Contract.current, id: "fixture", version: "1.0.0"))

        // Without the socket the fixture exits, and it is reaped.
        process.terminate()
        #expect(process.hasExited)
        #expect(!processExists(process.pid))
    }
}
