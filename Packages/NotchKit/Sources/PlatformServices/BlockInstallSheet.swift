import NotchCore
import SwiftUI

/// The words of the install and update sheet, from a package summary. Kept
/// apart from the view so they can be checked without drawing it.
struct InstallSheetText {
    let isUpdate: Bool
    let title: String
    /// The new version, with the installed one for an update.
    let version: String
    let contract: String
    /// One line per event; events the installed version did not listen to end in "(new)".
    let events: [String]
    let permissions: String
    /// What the block may do from inside its sandbox, one line each. Shown in
    /// place of `permissions` when not empty.
    let access: [String]
    /// "Signed by …" or "Not signed".
    let signature: String
    /// Shown under the signature when the package is not signed.
    let signatureWarning: String?
    let source: String
    let note = "Blocks run as their own process, limited to the access listed above. Install only blocks you built or trust."
    /// The default button.
    let confirm: String
    /// What an update keeps, or nil for a new install.
    let keeps: String?

    init(_ summary: BlockPackageSummary) {
        isUpdate = summary.installedVersion != nil
        title = isUpdate ? "Update \(summary.name)?" : "Install \(summary.name)?"
        version = summary.installedVersion.map { "\(summary.version) (installed: \($0))" } ?? summary.version
        contract = "Block contract \(summary.contract)"
        let new = Set(summary.newEvents)
        events = summary.events.map { new.contains($0) ? "\($0) (new)" : $0 }
        permissions = summary.permissions.isEmpty ? "Nothing" : summary.permissions.joined(separator: ", ")
        access = summary.access
        if summary.isSigned {
            signature = "Signed by \(summary.signer ?? "an unknown signer")"
            signatureWarning = nil
        } else {
            signature = "Not signed"
            signatureWarning = "TopNotch cannot tell who made this block or whether it was changed. Install it only if you built it or trust where it came from."
        }
        source = summary.sourcePath
        confirm = isUpdate ? "Update" : "Install and Turn On"
        keeps = isUpdate ? "Its settings and data are kept." : nil
    }
}

/// Shows what a package is and asks to install or update it. Return
/// confirms, Escape cancels.
struct BlockInstallSheet: View {
    let text: InstallSheetText
    let confirm: () -> Void
    let cancel: () -> Void

    init(summary: BlockPackageSummary, confirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        text = InstallSheetText(summary)
        self.confirm = confirm
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Version", value: text.version)
                    LabeledContent("Contract", value: text.contract)
                    LabeledContent("Listens to", value: text.events.isEmpty ? "Nothing" : text.events.joined(separator: "\n"))
                    if text.access.isEmpty {
                        LabeledContent("Needs", value: text.permissions)
                    } else {
                        LabeledContent("Access", value: text.access.joined(separator: "\n"))
                    }
                    LabeledContent("Signature", value: text.signature)
                    if let warning = text.signatureWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("From", value: text.source)
                } header: {
                    Text(text.title).font(.headline)
                } footer: {
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
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }
}
