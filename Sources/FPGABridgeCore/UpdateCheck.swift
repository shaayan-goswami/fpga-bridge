import Foundation

/// A version number like `0.2.1`, read from a release tag (`v0.2.1`) or the app's `CFBundleShortVersionString`.
/// Compared as semantic versions: numerically part by part, and a pre-release (`0.3.0-beta.1`) before its release.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// The dot-separated words after `-`, empty for a release.
    public var prerelease: [String]

    /// Accepts `1`, `1.2`, `1.2.3`, an optional leading `v`, a `-pre.release` and a `+build` (ignored, as semver says).
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            pre = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.contains(where: \.isEmpty) else { return nil }
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        (major, minor, patch, prerelease) = (numbers[0], numbers[1], numbers[2], pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A release is newer than any of its pre-releases.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true          // numeric words sort before words with letters
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// What GitHub says about a project's newest published release.
public struct LatestRelease: Codable, Equatable, Sendable {
    /// The release's tag, e.g. `v0.2.2`.
    public var tagName: String
    /// The release page, where the download is.
    public var htmlURL: URL
    public var draft: Bool
    public var prerelease: Bool

    public init(tagName: String, htmlURL: URL, draft: Bool = false, prerelease: Bool = false) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
    }

    public var version: SemanticVersion? { SemanticVersion(tagName) }
}

/// Where the latest release comes from. The app asks GitHub; tests and screenshot runs pass their own, so they never
/// touch the network.
public protocol ReleaseFetching: Sendable {
    func latestRelease() async throws -> LatestRelease
}

/// Asks GitHub's public API (no account needed) for the newest release of FPGA Bridge.
public struct GitHubReleaseFetcher: ReleaseFetching {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/shaayan-goswami/fpga-bridge/releases/latest")!

    let url: URL
    let userAgent: String

    public init(url: URL = GitHubReleaseFetcher.latestReleaseURL, appVersion: String) {
        self.url = url
        self.userAgent = "FPGA-Bridge/\(appVersion)"
    }

    public func latestRelease() async throws -> LatestRelease {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateCheckError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(LatestRelease.self, from: data)
    }
}

public enum UpdateCheckError: DescribedError, Equatable {
    case badResponse(Int)

    public var description: String {
        switch self {
        case .badResponse(let status): return "GitHub answered with HTTP status \(status)"
        }
    }
}

/// The rules for the update check, kept apart from the app so they can be tested.
public enum UpdateCheck {
    /// GitHub is asked at most this often.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether it is time to ask again. A clock set back (last check in the future) counts as due.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    /// The release's version, if it should be offered: newer than what is running, not the one the user skipped, and
    /// not a draft or pre-release. Nil when either version can't be read (a development build has none).
    public static func offer(_ release: LatestRelease, current: String?, skipped: String?) -> SemanticVersion? {
        guard !release.draft, !release.prerelease, let latest = release.version,
              let current = current.flatMap(SemanticVersion.init), latest > current else { return nil }
        if let skipped = skipped.flatMap(SemanticVersion.init), skipped == latest { return nil }
        return latest
    }
}
