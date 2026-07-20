import Foundation
import Security

/// Reads the Claude Code OAuth access token from the macOS Keychain.
/// Read-only; the token is never logged or written anywhere.
public struct KeychainCredentialReader {
    public enum ReadResult {
        case token(String)
        case notFound          // no Keychain entry → not signed in
        case denied            // user denied the Keychain prompt
        case failure(OSStatus)
    }

    public let service: String

    public init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    public func readAccessToken() -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else {
                return .notFound   // entry exists but shape unexpected → treat as not signed in
            }
            return .token(token)
        case errSecItemNotFound:
            return .notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        default:
            return .failure(status)
        }
    }
}
