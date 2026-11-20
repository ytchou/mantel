import Dispatch
import Foundation

/// Runs one block over one transport: sends `hello`, starts the block on
/// `welcome`, answers `ping`, delivers the rest, and ends on `quit` or when
/// the transport closes.
///
/// Frames are read and decoded off the main thread. Every message is then
/// handled on the main queue, in order, so a block's main thread is never
/// shared with the reader.
public final class Runner: Sendable {
    private let block: any Block
    private let transport: any Transport
    private let generation: Int

    /// `generation` is used for `hello`; after `welcome`, the block uses the
    /// welcome's generation. By default it is read from the
    /// `TOPNOTCH_BLOCK_GENERATION` environment variable the app sets.
    public init(block: any Block, transport: any Transport, generation: Int? = nil) {
        self.block = block
        self.transport = transport
        self.generation = generation
            ?? ProcessInfo.processInfo.environment["TOPNOTCH_BLOCK_GENERATION"].flatMap(Int.init)
            ?? 0
    }

    /// Returns when the app sends `quit`, closes the transport, or sends a
    /// frame that does not decode. The transport is closed on return.
    public func run() async {
        let block = self.block
        let transport = self.transport
        let generation = self.generation
        let context = await MainActor.run {
            let context = Context(transport: transport, generation: generation)
            context.send(.hello(contract: Contract.current, id: block.id, version: block.version))
            return context
        }

        do {
            receiving: for try await envelope in transport.envelopes(of: HostToBlock.self) {
                switch envelope.message {
                case .quit:
                    break receiving
                case let .ping(seq):
                    // Answered from the main queue: if the block's main thread
                    // is stuck, no pong goes out and the app sees a hang.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { _ = context.send(.pong(seq: seq)) }
                    }
                default:
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            context.receive(envelope) { block.start($0) }
                        }
                    }
                }
            }
        } catch {
            // A bad frame from the app. Say why if the socket still works,
            // then stop: the app restarts the block.
            await MainActor.run { context.log("stopping: \(error)") }
        }
        transport.close()
    }
}
