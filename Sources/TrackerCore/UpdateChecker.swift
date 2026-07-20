import Foundation

/// A release newer than what is running, resolved to its downloadable zip.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String          // normalized, no leading "v"
    public let downloadURL: URL
    public let releaseURL: URL

    public init(version: String, downloadURL: URL, releaseURL: URL) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseURL = releaseURL
    }
}

/// Polls the GitHub Releases API for a newer build and stages it on disk.
///
/// The app is ad-hoc signed and not notarized, which is fine for self-update:
/// a bundle downloaded programmatically carries no `com.apple.quarantine`
/// xattr, and Gatekeeper only gates *quarantined* first launches. (`spctl -a`
/// reports "rejected" for ad-hoc bundles even while the app runs happily —
/// it assesses the quarantine policy, it is not the execution gate.)
public struct UpdateChecker: Sendable {
    public static let defaultReleaseAPI = URL(string:
        "https://api.github.com/repos/nhannt315/tokei/releases/latest")!

    public let releaseAPI: URL

    public enum CheckError: Error, Equatable {
        case network(String)
        case http(Int)
        case badResponse
        case noZipAsset
    }

    public init(releaseAPI: URL = UpdateChecker.defaultReleaseAPI) {
        self.releaseAPI = releaseAPI
    }

    /// Nil when already current. Unauthenticated GitHub API allows 60 req/h per
    /// IP; callers poll on the order of hours, so no token is needed.
    public func check(currentVersion: String) async -> Result<AvailableUpdate?, CheckError> {
        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.badResponse) }
        guard http.statusCode == 200 else { return .failure(.http(http.statusCode)) }
        guard let release = Self.decode(data) else { return .failure(.badResponse) }
        guard Self.isNewer(release.version, than: currentVersion) else { return .success(nil) }
        return .success(release)
    }

    /// Tolerant decode of the releases payload: needs a tag and a `.zip` asset.
    /// Drafts and prereleases are ignored.
    public static func decode(_ data: Data) -> AvailableUpdate? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { return nil }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true { return nil }

        let assets = root["assets"] as? [[String: Any]] ?? []
        let zip = assets.first {
            ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true
        }
        guard let urlString = zip?["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else { return nil }

        let releaseURL = (root["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/nhannt315/tokei/releases/latest")!
        return AvailableUpdate(version: normalize(tag), downloadURL: downloadURL, releaseURL: releaseURL)
    }

    /// Strips a leading "v" and any build metadata `git describe` may append
    /// ("0.1.2-3-gabc123" → "0.1.2"), leaving a bare dotted version.
    public static func normalize(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        if let dash = v.firstIndex(of: "-") { v = String(v[v.startIndex..<dash]) }
        return v
    }

    /// Numeric component-wise compare, so 0.1.10 > 0.1.9 (a string compare
    /// would get that backwards). Missing components count as 0: 1.2 == 1.2.0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        guard !a.isEmpty else { return false }          // unparseable tag: never offer
        guard !b.isEmpty else { return true }           // unknown current: trust the release
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        let parts = normalize(version).split(separator: ".")
        let nums = parts.compactMap { Int($0) }
        return nums.count == parts.count ? nums : []    // any non-numeric part → unparseable
    }
}
