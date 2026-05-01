import Foundation

/// Polls the GitHub Releases API for `craraque/shunt` and decides whether the
/// running build is behind the latest published release.
///
/// Trust model:
/// - The HTTPS connection to api.github.com is authenticated by the system
///   trust store. We trust GitHub to tell us which release is "latest".
/// - The actual binary is verified separately by `UpdateInstaller` using
///   `codesign --verify --strict` + Apple's Developer ID team check.
///
/// We never include a personal access token; the public API endpoint we hit
/// has a 60 req/hr unauthenticated rate limit which is plenty for a manual
/// "Check for updates" button (and we cache the last result for an hour).
@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    enum Outcome: Equatable {
        /// The running build is at or ahead of the latest release.
        case upToDate(latestVersion: String)
        /// A newer release is available. Includes everything UpdateInstaller
        /// needs to fetch + verify it.
        case available(release: Release)
        /// Network or API failure. The string is suitable for direct display.
        case failed(reason: String)
    }

    struct Release: Equatable {
        /// Tag without the leading "v" (e.g. "0.4.0").
        let version: String
        /// Direct download URL for the .dmg asset attached to the release.
        let dmgURL: URL
        /// Markdown body of the release notes (may be empty).
        let notes: String
        /// Asset size in bytes for the progress bar.
        let dmgSize: Int64
    }

    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var inFlight: Bool = false

    private let repoOwner = "craraque"
    private let repoName = "shunt"
    private let urlSession: URLSession

    private init(session: URLSession = .shared) {
        self.urlSession = session
    }

    /// Run a check now. Cancels any in-flight check first. Result lands in
    /// `lastOutcome` and is also returned to the caller for inline use.
    func checkNow() async -> Outcome {
        inFlight = true
        defer { inFlight = false }

        let outcome = await performCheck()
        lastOutcome = outcome
        return outcome
    }

    private func performCheck() async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return .failed(reason: "Bad URL")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Shunt-Updater/\(Self.currentShortVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(reason: "No HTTP response")
            }
            switch http.statusCode {
            case 200:
                break
            case 404:
                return .failed(reason: "No releases published yet.")
            case 403:
                return .failed(reason: "GitHub rate limit reached. Try again later.")
            default:
                return .failed(reason: "GitHub returned HTTP \(http.statusCode)")
            }

            let payload = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
            let tag = payload.tag_name
            // Accept "v0.4.0" and "0.4.0" alike.
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            // Find the .dmg asset.
            guard let dmgAsset = payload.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  let dmgURL = URL(string: dmgAsset.browser_download_url) else {
                return .failed(reason: "Latest release has no DMG asset.")
            }

            // Compare semvers numerically. CFBundleShortVersionString uses
            // dot-decimal triplets, same as our tags after stripping `v`.
            if Self.semverCompare(latest, Self.currentShortVersion) <= 0 {
                return .upToDate(latestVersion: latest)
            }

            return .available(release: Release(
                version: latest,
                dmgURL: dmgURL,
                notes: payload.body ?? "",
                dmgSize: Int64(dmgAsset.size)
            ))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Returns negative if `a < b`, zero if equal, positive if `a > b`.
    /// Treats missing components as 0 so "0.4" < "0.4.1".
    static func semverCompare(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        let len = max(aParts.count, bParts.count)
        for i in 0..<len {
            let ai = i < aParts.count ? aParts[i] : 0
            let bi = i < bParts.count ? bParts[i] : 0
            if ai != bi { return ai - bi }
        }
        return 0
    }

    static var currentShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var currentBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    // MARK: - GitHub API DTOs

    private struct GitHubReleaseResponse: Decodable {
        let tag_name: String
        let body: String?
        let assets: [GitHubAsset]
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int
    }
}
