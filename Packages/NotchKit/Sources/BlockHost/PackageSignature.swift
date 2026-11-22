import Foundation
import Security

/// The code signature of a `.mantelblock` bundle, as the Security framework sees it.
enum PackageSignature: Sendable, Equatable {
    /// A valid signature with a certificate. `teamID` is empty when the
    /// certificate has none.
    case valid(signer: String, teamID: String)
    /// A valid signature without a signer (`codesign --sign -`).
    case adHoc
    case unsigned
    /// Signed, but the seal does not hold: a file changed, was added or removed.
    case invalid(reason: String)

    /// Checks `bundle` strictly, nested code and every architecture included.
    static func check(_ bundle: URL) -> PackageSignature {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return .invalid(reason: message(status)) }

        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures))
        status = SecStaticCodeCheckValidity(staticCode, flags, nil)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess else { return .invalid(reason: message(status)) }

        var information: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            return .invalid(reason: message(status))
        }

        let rawFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        guard !SecCodeSignatureFlags(rawValue: rawFlags).contains(.adhoc), let leaf = certificates.first else {
            return .adHoc
        }
        let signer = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        return .valid(signer: signer, teamID: teamID)
    }

    private static func message(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown signature error"
        return "\(text) (\(status))"
    }
}

/// Checks a package's signature. Tests inject fixed results.
protocol SignatureChecking: Sendable {
    func check(_ bundle: URL) -> PackageSignature
}

/// The real check, through the Security framework.
struct SystemSignatureChecker: SignatureChecking {
    func check(_ bundle: URL) -> PackageSignature { PackageSignature.check(bundle) }
}
