import AppKit
import MackyCore

/// Controls the Spotify app directly through its AppleScript interface: no screenshots, no clicks,
/// no guessing. Every command is checked afterwards by asking Spotify what is actually playing,
/// so Macky never says "it's playing" when it is not.
@MainActor
final class SpotifyController {
    struct Outcome {
        var succeeded: Bool
        /// Shown in the bubble and, on failure, spoken.
        var message: String
    }

    private struct PlayerStatus {
        var isPlaying: Bool
        var trackIdentifier: String
        var trackName: String
        var artistName: String
        var albumName: String

        var description: String {
            trackName.isEmpty ? "nimic" : "„\(trackName)” – \(artistName)"
        }
    }

    private static let bundleIdentifier = "com.spotify.client"
    private static let playLabels = ["Play", "Redă", "Reda", "Lecture", "Reproducir", "Wiedergabe"]

    private let executor: ScreenActionExecutor
    private let elementFinder: AccessibilityElementFinder
    private let webAPIClient = SpotifyWebAPIClient()
    private let credentialsStore: SpotifyCredentialsStore
    /// Kept to tell a missing Automation permission apart from Spotify still starting.
    private var lastAppleScriptError = ""

    init(executor: ScreenActionExecutor, elementFinder: AccessibilityElementFinder, credentialsStore: SpotifyCredentialsStore) {
        self.executor = executor
        self.elementFinder = elementFinder
        self.credentialsStore = credentialsStore
    }

    /// Fetches the search token ahead of time so the first request is fast.
    func warmUp() {
        guard let clientIdentifier = credentialsStore.clientIdentifier, let clientSecret = credentialsStore.clientSecret else { return }
        let webAPIClient = self.webAPIClient
        Task.detached {
            _ = try? await webAPIClient.accessToken(clientIdentifier: clientIdentifier, clientSecret: clientSecret)
        }
    }

    func perform(_ command: SpotifyCommand) async -> Outcome {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) != nil else {
            return Outcome(succeeded: false, message: "Spotify nu e instalat pe Mac.")
        }
        guard await ensureSpotifyIsRunning() else {
            if lastAppleScriptError.contains("-1743") || lastAppleScriptError.lowercased().contains("not authorized") {
                return Outcome(succeeded: false, message: "Macky nu are voie să controleze Spotify. Permite-l în System Settings → Privacy & Security → Automation → Macky → Spotify.")
            }
            return Outcome(succeeded: false, message: "Spotify nu a pornit la timp. Mai încearcă o dată.")
        }
        let statusBefore = await playerStatus()

        switch command {
        case .pause:
            _ = await runSpotifyScript("pause")
            return await verify(expectingPlaying: false, successMessage: "Pauză.")
        case .resume:
            _ = await runSpotifyScript("play")
            return await verify(expectingPlaying: true, successMessage: nil)
        case .nextTrack:
            _ = await runSpotifyScript("next track")
            return await verifyTrackChanged(from: statusBefore)
        case .previousTrack:
            _ = await runSpotifyScript("previous track")
            return await verifyTrackChanged(from: statusBefore)
        case .playLikedSongs:
            return await playLikedSongs(statusBefore: statusBefore)
        case .play(let query, let kind):
            return await play(query: query, kind: kind, statusBefore: statusBefore)
        }
    }

    // MARK: Commands

    private func playLikedSongs(statusBefore: PlayerStatus?) async -> Outcome {
        // 1. Direct: play the Liked Songs collection by its link (needs the username from Spotify's prefs file).
        if let username = Self.spotifyUsername() {
            let uri = SpotifyHelpers.likedSongsURI(username: username)
            if await runSpotifyScript("play track \(SpotifyHelpers.appleScriptString(uri))"),
               let status = await waitForPlayback(changedFrom: statusBefore) {
                return Outcome(succeeded: true, message: "▶ \(status.description)")
            }
        }
        // 2. Fallback: open Liked Songs and press its big Play button.
        _ = executor.openURL("spotify:collection:tracks")
        try? await Task.sleep(nanoseconds: 600_000_000)
        _ = await elementFinder.pressElement(anyOf: Self.playLabels, applicationName: "Spotify", timeout: 3)
        if let status = await waitForPlayback(changedFrom: statusBefore) {
            return Outcome(succeeded: true, message: "▶ \(status.description)")
        }
        return Outcome(succeeded: false, message: "Nu am reușit să pornesc Liked Songs.")
    }

    private func play(query: String, kind: SpotifySearchKind, statusBefore: PlayerStatus?) async -> Outcome {
        // 1. Precise: search Spotify's catalog, then play that exact link.
        if let clientIdentifier = credentialsStore.clientIdentifier, let clientSecret = credentialsStore.clientSecret {
            do {
                let searchResult = try await webAPIClient.search(query: query, kind: kind, clientIdentifier: clientIdentifier, clientSecret: clientSecret)
                if await runSpotifyScript("play track \(SpotifyHelpers.appleScriptString(searchResult.uri))"),
                   let status = await waitForPlayback(changedFrom: statusBefore) {
                    return Outcome(succeeded: true, message: "▶ \(status.description)")
                }
                return Outcome(succeeded: false, message: "Am găsit „\(searchResult.name)”, dar Spotify nu a pornit-o.")
            } catch SpotifyWebAPIError.nothingFound {
                return Outcome(succeeded: false, message: "Nu am găsit „\(query)” pe Spotify.")
            } catch {
                // Network or credential problem: fall through to the app-only route.
            }
        }

        // 2. Without search credentials: open Spotify's search and press the top result's Play button.
        _ = executor.openURL("spotify:search:" + query)
        try? await Task.sleep(nanoseconds: 900_000_000)
        _ = await elementFinder.pressElement(anyOf: Self.playLabels, applicationName: "Spotify", timeout: 3)
        guard let status = await waitForPlayback(changedFrom: statusBefore) else {
            return Outcome(succeeded: false, message: "Nu am reușit să pornesc „\(query)”. Adaugă datele Spotify în Setări ca să caut precis.")
        }
        if kind == .track && !SpotifyHelpers.nowPlaying(trackName: status.trackName, artistName: status.artistName, albumName: status.albumName, matches: query) {
            return Outcome(succeeded: false, message: "A pornit \(status.description), nu sunt sigur că e ce ai cerut.")
        }
        return Outcome(succeeded: true, message: "▶ \(status.description)")
    }

    // MARK: Verification

    private func verify(expectingPlaying: Bool, successMessage: String?) async -> Outcome {
        for _ in 0..<8 {
            if let status = await playerStatus(), status.isPlaying == expectingPlaying {
                return Outcome(succeeded: true, message: successMessage ?? "▶ \(status.description)")
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return Outcome(succeeded: false, message: expectingPlaying ? "Spotify nu a pornit redarea." : "Spotify nu s-a oprit.")
    }

    private func verifyTrackChanged(from statusBefore: PlayerStatus?) async -> Outcome {
        if let status = await waitForPlayback(changedFrom: statusBefore) {
            return Outcome(succeeded: true, message: "▶ \(status.description)")
        }
        return Outcome(succeeded: false, message: "Spotify nu a schimbat melodia.")
    }

    /// Waits up to ~3 s until Spotify is playing something other than before (or anything, if it was stopped).
    private func waitForPlayback(changedFrom statusBefore: PlayerStatus?) async -> PlayerStatus? {
        for _ in 0..<15 {
            if let status = await playerStatus(), status.isPlaying {
                let wasPlayingSameTrack = statusBefore?.isPlaying == true && statusBefore?.trackIdentifier == status.trackIdentifier
                if !wasPlayingSameTrack { return status }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Same track restarted (e.g. Liked Songs already playing from the top) still counts as playing.
        if let status = await playerStatus(), status.isPlaying, statusBefore?.isPlaying == false || statusBefore == nil {
            return status
        }
        return nil
    }

    // MARK: Spotify app

    private func ensureSpotifyIsRunning() async -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        }
        // Spotify answers AppleScript only once it has finished starting.
        for _ in 0..<40 {
            if await playerStatus() != nil { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func playerStatus() async -> PlayerStatus? {
        let script = """
        tell application "Spotify"
            set stateText to player state as string
            try
                set trackText to (id of current track) & "|#|" & (name of current track) & "|#|" & (artist of current track) & "|#|" & (album of current track)
            on error
                set trackText to "|#||#||#|"
            end try
            return stateText & "|#|" & trackText
        end tell
        """
        let result = await executor.runAppleScript(script)
        guard result.succeeded else {
            lastAppleScriptError = result.output
            return nil
        }
        let parts = result.output.components(separatedBy: "|#|")
        guard parts.count >= 5 else { return nil }
        return PlayerStatus(isPlaying: parts[0] == "playing", trackIdentifier: parts[1], trackName: parts[2], artistName: parts[3], albumName: parts[4])
    }

    @discardableResult
    private func runSpotifyScript(_ command: String) async -> Bool {
        await executor.runAppleScript("tell application \"Spotify\" to \(command)").succeeded
    }

    private static func spotifyUsername() -> String? {
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Spotify/prefs")
        guard let preferencesText = try? String(contentsOf: preferencesURL, encoding: .utf8) else { return nil }
        return SpotifyHelpers.username(fromPreferencesText: preferencesText)
    }
}
