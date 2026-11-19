// Throwaway spike: a small copy of the block contract, built as a dynamic
// library so a host and separately built plugins can share it.
//
// Mirrors the real NotchCore shape: a @MainActor class-bound protocol, value
// types, an enum of input, and a SwiftUI view returned as AnyView.
//
// Version-skew variants are compiled from this one file with -D flags:
//   V2_ADDREQ   add a protocol requirement with a default implementation
//   V2_STRUCT   add a stored property to a public struct (old init kept)
//   V2_ENUM     add an enum case
//   V2_REORDER  swap two struct fields and two protocol requirements
//   V2_REMOVE   remove a method from BlockContext
import SwiftUI

/// Inlined into the plugin when it is built, so the host can read which
/// contract version the plugin was compiled against.
@inlinable public var blockContractVersion: Int {
    #if V2_ADDREQ || V2_STRUCT || V2_ENUM || V2_REORDER || V2_REMOVE
    return 2
    #else
    return 1
    #endif
}

public struct BlockInfo: Sendable, Equatable {
    #if V2_REORDER
    public var symbol: String
    public var summary: String
    #else
    public var summary: String
    public var symbol: String
    #endif
    #if V2_STRUCT
    public var trigger: String
    #endif

    public init(summary: String, symbol: String) {
        self.summary = summary
        self.symbol = symbol
        #if V2_STRUCT
        self.trigger = "(default)"
        #endif
    }

    #if V2_STRUCT
    public init(summary: String, symbol: String, trigger: String) {
        self.summary = summary
        self.symbol = symbol
        self.trigger = trigger
    }
    #endif
}

public enum NotchInput: Sendable {
    case click
    case drop([String])
    #if V2_ENUM
    case hover(Bool)
    #endif
}

@MainActor
public struct Presentation {
    public var priority: Int
    public var size: CGSize
    public let makeView: @MainActor () -> AnyView

    public init<V: View>(priority: Int = 1, size: CGSize, @ViewBuilder _ view: @escaping @MainActor () -> V) {
        self.priority = priority
        self.size = size
        self.makeView = { AnyView(view()) }
    }
}

@MainActor
public protocol BlockContext: AnyObject {
    func present(_ presentation: Presentation)
    #if !V2_REMOVE
    func log(_ message: String)
    #endif
}

@MainActor
public protocol PluginBlock: AnyObject {
    #if V2_REORDER
    var title: String { get }
    var id: String { get }
    #else
    var id: String { get }
    var title: String { get }
    #endif
    var info: BlockInfo { get }
    func activate(_ context: any BlockContext)
    /// Returns what the block did, so the host can see misbehaviour.
    func handle(_ input: NotchInput) -> String
    #if V2_ADDREQ
    var priorityHint: Int { get }
    #endif
}

#if V2_ADDREQ
public extension PluginBlock {
    var priorityHint: Int { 42 }
}
#endif
