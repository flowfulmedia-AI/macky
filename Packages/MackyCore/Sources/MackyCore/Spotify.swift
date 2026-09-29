import Foundation

public enum SpotifySearchKind: String, Equatable, Sendable {
    case track
    case album
    case artist
    case playlist
}

/// Everything Macky can do with Spotify directly, without looking at the screen.
public enum SpotifyCommand: Equatable, Sendable {
    case play(query: String, kind: SpotifySearchKind)
    case playLikedSongs
    case pause
    case resume
    case nextTrack
    case previousTrack

    public var userFacingDescription: String {
        switch self {
        case .play(let query, _): return "Pornește „\(query)” pe Spotify"
        case .playLikedSongs: return "Pornește Liked Songs pe Spotify"
        case .pause: return "Pauză pe Spotify"
        case .resume: return "Continuă pe Spotify"
        case .nextTrack: return "Melodia următoare pe Spotify"
        case .previousTrack: return "Melodia anterioară pe Spotify"
        }
    }

    /// Parses the model's `spotify` tool call.
    public init?(toolArgumentsJSON: String) {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = (arguments["action"] as? String)?.lowercased() else { return nil }
        switch action {
        case "play":
            guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return nil }
            let kind = SpotifySearchKind(rawValue: (arguments["kind"] as? String)?.lowercased() ?? "track") ?? .track
            self = .play(query: query, kind: kind)
        case "play_liked_songs", "liked_songs": self = .playLikedSongs
        case "pause": self = .pause
        case "resume": self = .resume
        case "next": self = .nextTrack
        case "previous": self = .previousTrack
        default: return nil
        }
    }
}

/// Recognizes spoken Spotify requests locally, so they skip the model entirely.
public enum SpotifyCommandMatcher {
    private static let maximumWordCount = 16

    public static func match(_ transcript: String) -> SpotifyCommand? {
        var text = fold(QuickCommandMatcher.normalize(transcript))
        guard !text.isEmpty, text.split(separator: " ").count <= maximumWordCount else { return nil }

        let mentionsSpotify = text.contains("spotify")
        for phrase in [" pe spotify", " de pe spotify", " din spotify", " in spotify", " la spotify", " cu spotify", " on spotify", " spotify"] {
            text = text.replacingOccurrences(of: phrase, with: "")
        }
        text = text.trimmingCharacters(in: .whitespaces)

        if likedSongsPhrases.contains(where: { text.contains($0) }) {
            return .playLikedSongs
        }

        if mentionsSpotify {
            if ["pauza", "opreste", "stop", "pause"].contains(where: { text.contains($0) }) { return .pause }
            if ["urmatoarea", "next", "skip", "mai departe"].contains(where: { text.contains($0) }) { return .nextTrack }
            if ["anterioara", "previous", "dinainte"].contains(where: { text.contains($0) }) { return .previousTrack }
        }

        guard let (verb, remainder) = splitPlayVerb(from: text) else { return nil }
        var query = remainder
        var kind = SpotifySearchKind.track
        var hasMusicWord = mentionsSpotify

        for (leadingWords, leadingKind) in leadingKindWords {
            if let matchedPrefix = leadingWords.first(where: { query.hasPrefix($0 + " ") }) {
                query = String(query.dropFirst(matchedPrefix.count + 1))
                kind = leadingKind
                hasMusicWord = true
                break
            }
        }
        // "ceva de la Queen" / "muzica de la Queen" → artist.
        for artistPrefix in ["ceva de la ", "ceva de ", "muzica de la ", "muzica lui ", "melodii de la ", "piese de la ", "something by ", "music by ", "songs by "] where query.hasPrefix(artistPrefix) {
            query = String(query.dropFirst(artistPrefix.count))
            kind = .artist
            hasMusicWord = true
        }
        // "Numb de la Linkin Park" → search "Numb Linkin Park".
        query = query.replacingOccurrences(of: " de la ", with: " ").replacingOccurrences(of: " by ", with: " ")
        for trailing in [" te rog", " please", " acum", " now"] where query.hasSuffix(trailing) {
            query = String(query.dropLast(trailing.count))
        }
        query = query.trimmingCharacters(in: .whitespaces)

        // "pornește Safari" is an app, not a song: ambiguous verbs need a music word.
        let verbIsAlwaysMusic = musicOnlyVerbs.contains(verb)
        guard verbIsAlwaysMusic || hasMusicWord else { return nil }
        if query.isEmpty || ["muzica", "muzica mea", "music", "ceva", "something"].contains(query) {
            return .resume
        }
        guard !["pauza", "pauze"].contains(query) else { return nil }
        return .play(query: query, kind: kind)
    }

    private static func splitPlayVerb(from text: String) -> (verb: String, remainder: String)? {
        for verb in playVerbs where text.hasPrefix(verb + " ") || text == verb {
            let remainder = text == verb ? "" : String(text.dropFirst(verb.count + 1))
            return (verb, remainder.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static let likedSongsPhrases = [
        "liked songs", "like songs", "melodiile apreciate", "melodii apreciate", "piesele apreciate", "melodiile placute",
        "melodiile preferate", "piesele preferate", "melodiile mele preferate", "favoritele mele", "my liked songs"
    ]
    /// Longest first so "da drumul la" wins over "da".
    static let playVerbs = [
        "vreau sa ascult", "da-mi drumul la", "da drumul la", "pune-mi", "porneste-mi", "canta-mi", "reda", "pune", "porneste",
        "canta", "asculta", "play", "start playing", "listen to"
    ]
    static let musicOnlyVerbs: Set<String> = ["vreau sa ascult", "da-mi drumul la", "da drumul la", "pune-mi", "pune", "canta", "canta-mi", "reda", "asculta", "play", "start playing", "listen to"]
    static let leadingKindWords: [([String], SpotifySearchKind)] = [
        (["melodia", "piesa", "cantecul", "melodie", "piesă", "the song", "song"], .track),
        (["albumul", "album", "the album"], .album),
        (["playlistul", "playlist", "the playlist"], .playlist),
        (["artistul", "trupa", "formatia", "the artist", "artist"], .artist)
    ]
}

public enum SpotifyHelpers {
    /// Reads the logged-in username from Spotify's local `prefs` file
    /// (~/Library/Application Support/Spotify/prefs), needed for the Liked Songs link.
    public static func username(fromPreferencesText preferencesText: String) -> String? {
        for key in ["autologin.canonical_username", "autologin.username"] {
            if let range = preferencesText.range(of: key + #"="([^"]+)""#, options: .regularExpression) {
                let line = String(preferencesText[range])
                let value = line.dropFirst(key.count + 2).dropLast()
                if !value.isEmpty { return String(value) }
            }
        }
        return nil
    }

    public static func likedSongsURI(username: String) -> String {
        "spotify:user:\(username):collection"
    }

    /// Whether what is now playing plausibly is what the user asked for (most query words appear).
    public static func nowPlaying(trackName: String, artistName: String, albumName: String, matches query: String) -> Bool {
        let haystack = SpotifyCommandMatcher.fold("\(trackName) \(artistName) \(albumName)")
        let queryWords = SpotifyCommandMatcher.fold(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !queryWords.isEmpty else { return true }
        let foundWordCount = queryWords.filter { haystack.contains($0) }.count
        return Double(foundWordCount) / Double(queryWords.count) >= 0.5
    }

    /// Escapes text for use inside an AppleScript string literal.
    public static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
