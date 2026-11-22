import NotchCore
import SwiftUI

/// The words of the install, update and review sheet, from a package
/// summary. Kept apart from the view so they can be checked without drawing it.
struct InstallSheetText {
    /// One event the block listens to, as the sheet lists it.
    struct Event: Equatable {
        /// Ends in "(new)" for an event the installed version did not listen to.
        let name: String
        let reveals: String
        /// The macOS permission its source needs, or "No macOS permission".
        let permission: String
        /// Anything else the owner should know, or nil.
        let note: String?
    }

    let isUpdate: Bool
    let title: String
    /// The new version, with the installed one for an update.
    let version: String
    let contract: String
    /// One entry per event, in the manifest's order.
    let events: [Event]
    /// What the block may do from inside its sandbox, one line each, or "Nothing".
    let access: String
    /// The hosts under "Can reach", in the manifest's order; a host the
    /// installed version could not reach ends in "(new)". Empty: no row.
    let hosts: [String]
    /// Who made the block: the signer, or that it cannot be verified.
    let creator: String
    /// Shown under the creator when the package is not signed.
    let creatorNote: String?
    /// The warning for a risky pair of access, naming every host, or nil.
    let warning: String?
    /// The label of the confirmation a risky pair needs, or nil when it needs none.
    let acknowledgement: String?
    let source: String
    let note = "Blocks run as their own process, limited to the access listed above. Install only blocks you built or trust."
    /// The default button.
    let confirm: String
    /// What an update keeps, or nil for a new install and a review.
    let keeps: String?

    /// - Parameter review: true for a block waiting for review in the Blocks
    ///   folder: the sheet approves it where it is.
    init(_ summary: BlockPackageSummary, review: Bool = false) {
        isUpdate = !review && summary.installedVersion != nil
        title = review ? "Approve \(summary.name)?" : isUpdate ? "Update \(summary.name)?" : "Install \(summary.name)?"
        version = summary.installedVersion.map { "\(summary.version) (installed: \($0))" } ?? summary.version
        contract = "Block contract \(summary.contract)"
        let newEvents = Set(summary.newEvents)
        events = summary.eventEntries.map { entry in
            Event(name: newEvents.contains(entry.name) ? "\(entry.name) (new)" : entry.name,
                  reveals: entry.reveals,
                  permission: Self.permission(entry.permission),
                  note: entry.note.isEmpty ? nil : entry.note)
        }
        access = summary.access.isEmpty ? "Nothing" : summary.access.joined(separator: "\n")
        let newHosts = Set(summary.newHosts)
        hosts = summary.hosts.map { newHosts.contains($0) ? "\($0) (new)" : $0 }
        if let signer = summary.signer {
            creator = signer
            creatorNote = nil
        } else {
            creator = "No signature: the creator cannot be verified"
            creatorNote = "Your approval covers this exact build. A changed copy asks again."
        }
        switch summary.riskyPair {
        case .files?:
            warning = "This block can read your files and send data to \(Self.list(summary.hosts)). Install it only if you trust its creator."
        case .screenshots?:
            warning = "This block can read your screenshots and send data to \(Self.list(summary.hosts)). Install it only if you trust its creator."
        case nil:
            warning = nil
        }
        acknowledgement = warning == nil ? nil : "I understand that this block can send my files to these hosts"
        source = summary.sourcePath
        confirm = review ? "Approve and Turn On" : isUpdate ? "Update" : "Install and Turn On"
        keeps = isUpdate ? "Its settings and data are kept." : nil
    }

    /// The default button is enabled once a risky pair is acknowledged;
    /// always for any other block.
    func canConfirm(acknowledged: Bool) -> Bool {
        acknowledgement == nil || acknowledged
    }

    private static func permission(_ permission: EventEntry.Permission) -> String {
        switch permission {
        case .none: "No macOS permission"
        case .screenshotFolder: "Access to the screenshot folder"
        }
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Shows what a package is and asks to install, update or approve it.
/// Return confirms, Escape cancels. A risky pair of access needs its
/// confirmation ticked first.
struct BlockInstallSheet: View {
    let text: InstallSheetText
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var acknowledged = false

    init(summary: BlockPackageSummary, review: Bool = false, confirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        text = InstallSheetText(summary, review: review)
        self.confirm = confirm
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Version", value: text.version)
                    LabeledContent("Contract", value: text.contract)
                    LabeledContent("Listens to") {
                        if text.events.isEmpty {
                            Text("Nothing")
                        } else {
                            VStack(alignment: .trailing, spacing: 6) {
                                ForEach(text.events, id: \.name) { event in
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(event.name)
                                        Text(event.reveals).font(.caption).foregroundStyle(.secondary)
                                        Text(event.permission).font(.caption).foregroundStyle(.secondary)
                                        if let note = event.note {
                                            Text(note).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                    LabeledContent("Access", value: text.access)
                    if !text.hosts.isEmpty {
                        LabeledContent("Can reach", value: text.hosts.joined(separator: "\n"))
                    }
                    LabeledContent("Creator", value: text.creator)
                    if let note = text.creatorNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("From", value: text.source)
                } header: {
                    Text(text.title).font(.headline)
                }
                // The warning comes before the checkbox, so it is read first.
                if let warning = text.warning, let acknowledgement = text.acknowledgement {
                    Section {
                        ReasonBox(kind: .warning, text: warning)
                        Toggle(acknowledgement, isOn: $acknowledged)
                            .toggleStyle(.checkbox)
                    }
                }
                Section {} footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let keeps = text.keeps { Text(keeps) }
                        Text(text.note)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(text.confirm, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!text.canConfirm(acknowledged: acknowledged))
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }
}

/// A box with an icon, words and an optional action inside: red for a
/// block that was stopped, orange for a warning. The icon and the words say
/// what it is; the color only repeats it.
struct ReasonBox<Action: View>: View {
    enum Kind {
        /// The block was stopped, with the reason.
        case stopped
        /// Something to know before going on, or about a block that runs.
        case warning

        var tint: Color { self == .stopped ? .red : .orange }
    }

    let kind: Kind
    let text: String
    @ViewBuilder let action: () -> Action

    init(kind: Kind, text: String, @ViewBuilder action: @escaping () -> Action) {
        self.kind = kind
        self.text = text
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(kind.tint)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            action()
        }
        .padding(10)
        .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(kind.tint.opacity(0.5)))
    }
}

extension ReasonBox where Action == EmptyView {
    init(kind: Kind, text: String) {
        self.init(kind: kind, text: text) { EmptyView() }
    }
}
