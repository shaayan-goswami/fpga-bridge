import AppKit
import FPGABridgeCore
import SwiftUI

/// The in-app update check. At launch, at most once a day, asks GitHub for the newest release and, if it is newer than
/// this app, shows a small notice with a Download button that opens the release page. Offline or on any error it says
/// nothing. Settings > General turns it off; the notice can skip a version for good.
@MainActor
final class UpdateChecker: ObservableObject {
    /// A newer release to offer.
    struct Available: Equatable {
        var version: String
        var page: URL
    }

    /// What Check Now found, for Settings.
    enum ManualResult: Equatable {
        case upToDate(String)
        case available(String)
        case failed(String)
    }

    enum Key {
        static let enabled = "updates.checkAutomatically"
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
        /// The newest release seen, so the notice is still there on the next launch the same day.
        static let latestTag = "updates.latestTag"
        static let latestPage = "updates.latestPage"
    }

    /// The release page for a version, when GitHub hasn't given one.
    static let releasesPage = URL(string: "https://github.com/shaayan-goswami/fpga-bridge/releases/latest")!

    @Published private(set) var available: Available?
    @Published private(set) var isChecking = false
    @Published private(set) var manualResult: ManualResult?

    /// This app's version (`CFBundleShortVersionString`). Nil under `swift run`, which turns the check off.
    let currentVersion: String?
    private let fetcher: (any ReleaseFetching)?
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Opens the release page. Replaced in tests.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// `fetcher` nil means never ask (screenshot runs, tests that don't care).
    init(currentVersion: String?, fetcher: (any ReleaseFetching)?, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.fetcher = fetcher
        self.defaults = defaults
        self.now = now
    }

    /// The checker the app uses: GitHub in a real .app, nothing at all in debug screenshot runs.
    static func make() -> UpdateChecker {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["FPGA_BRIDGE_FAKE_UPDATE"] {
            // Shows the notice for screenshots, with no network and nothing remembered.
            let defaults = UserDefaults(suiteName: "FPGABridge.debug-updates") ?? .standard
            defaults.removePersistentDomain(forName: "FPGABridge.debug-updates")
            return UpdateChecker(currentVersion: "0.2.1", fetcher: FixedRelease(tag: fake), defaults: defaults)
        }
        if Snapshot.isRequested || DebugHooks.forceDemo { return UpdateChecker(currentVersion: version, fetcher: nil) }
        #endif
        return UpdateChecker(currentVersion: version, fetcher: version.map { GitHubReleaseFetcher(appVersion: $0) })
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.enabled)
            if !newValue { available = nil }
        }
    }

    var lastCheck: Date? { defaults.object(forKey: Key.lastCheck) as? Date }
    var skippedVersion: String? { defaults.string(forKey: Key.skipped) }

    /// At launch: shows what an earlier check found, then asks GitHub if a day has passed since the last time.
    func checkAtLaunchIfDue() async {
        guard isEnabled, fetcher != nil, currentVersion != nil else { return }
        if let tag = defaults.string(forKey: Key.latestTag) {
            let page = defaults.string(forKey: Key.latestPage).flatMap(URL.init(string:)) ?? Self.releasesPage
            offer(LatestRelease(tagName: tag, htmlURL: page))
        }
        guard UpdateCheck.isDue(lastCheck: lastCheck, now: now()) else { return }
        _ = await check()
    }

    /// Settings' Check Now: asks GitHub whatever the time, and says what it found.
    func checkNow() async {
        guard let currentVersion else {
            manualResult = .failed("This copy of FPGA Bridge has no version number (a development build), so it can't be compared.")
            return
        }
        guard fetcher != nil else { manualResult = .failed("Update checks are off in this run."); return }
        manualResult = nil
        switch await check(manual: true) {
        case .success(let release):
            if let offered = UpdateCheck.offer(release, current: currentVersion, skipped: nil) {
                manualResult = .available(offered.description)
            } else {
                manualResult = .upToDate(currentVersion)
            }
        case .failure(let error):
            manualResult = .failed("Couldn't reach GitHub: \(error.userMessage)")
        }
    }

    @discardableResult
    private func check(manual: Bool = false) async -> Result<LatestRelease, Error> {
        guard let fetcher, !isChecking else { return .failure(CancellationError()) }
        isChecking = true
        defer { isChecking = false }
        // Recorded before asking, so a failure (offline, GitHub down) also waits a day: "at most once a day".
        defaults.set(now(), forKey: Key.lastCheck)
        do {
            let release = try await fetcher.latestRelease()
            defaults.set(release.tagName, forKey: Key.latestTag)
            defaults.set(release.htmlURL.absoluteString, forKey: Key.latestPage)
            if manual { defaults.removeObject(forKey: Key.skipped) }
            offer(release)
            return .success(release)
        } catch {
            return .failure(error)
        }
    }

    private func offer(_ release: LatestRelease) {
        guard isEnabled, let version = UpdateCheck.offer(release, current: currentVersion, skipped: skippedVersion) else {
            available = nil
            return
        }
        available = Available(version: version.description, page: release.htmlURL)
    }

    /// Hides the notice until the next launch.
    func dismiss() { available = nil }

    /// Never offers this version again; a newer one still shows.
    func skipThisVersion() {
        guard let available else { return }
        defaults.set(available.version, forKey: Key.skipped)
        self.available = nil
    }

    func download() {
        guard let available else { return }
        openURL(available.page)
        self.available = nil
    }
}

#if DEBUG
/// A pretend GitHub for screenshots (`FPGA_BRIDGE_FAKE_UPDATE=0.3.0`).
private struct FixedRelease: ReleaseFetching {
    let tag: String
    func latestRelease() async throws -> LatestRelease {
        LatestRelease(tagName: "v\(tag)", htmlURL: URL(string: "https://github.com/shaayan-goswami/fpga-bridge/releases/tag/v\(tag)")!)
    }
}
#endif

/// The notice in the corner of the window: "FPGA Bridge 0.2.2 is available", Download, and a menu to skip it.
struct UpdateBanner: View {
    @EnvironmentObject private var updates: UpdateChecker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack { notice }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: updates.available?.version)
    }

    @ViewBuilder private var notice: some View {
        if let available = updates.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Accent.active)
                VStack(alignment: .leading, spacing: 1) {
                    Text("FPGA Bridge \(available.version) is available").font(.callout.weight(.semibold))
                    if let current = updates.currentVersion {
                        Text("You have \(current).").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Download") { updates.download() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Open the release page on GitHub")
                Menu {
                    Button("Skip This Version") { updates.skipThisVersion() }
                    Button("Remind Me Later") { updates.dismiss() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Skip this version, or be reminded at the next launch")
                Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close. The notice comes back at the next launch.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassSurface(cornerRadius: 14)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.trailing, 16)
            .padding(.bottom, 64)
            .transition(reduceMotion ? .opacity : .offset(y: 12).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("FPGA Bridge \(available.version) is available")
        }
    }
}
