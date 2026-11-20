// Entry point that turns the real DemoBlock (compiled from
// Packages/NotchKit/Sources/DemoBlock/DemoBlock.swift, unchanged) into a
// plugin built against the real NotchCore, built as a dynamic library.
import NotchCore

/// Returns a +1 retained DemoBlock as a pointer bit pattern (UInt is Sendable,
/// a raw pointer is not, and assumeIsolated needs a Sendable result).
@_cdecl("topnotch_block_entry")
public func topnotchBlockEntry() -> UInt {
    MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(DemoBlock() as AnyObject).toOpaque())
    }
}
