import XCTest
@testable import MackyCore

final class SpotifyCommandMatcherTests: XCTestCase {
    func testLikedSongs() {
        XCTAssertEqual(SpotifyCommandMatcher.match("Pornește-mi prima melodie de la liked songs din Spotify."), .playLikedSongs)
        XCTAssertEqual(SpotifyCommandMatcher.match("pune melodiile apreciate"), .playLikedSongs)
        XCTAssertEqual(SpotifyCommandMatcher.match("Play my liked songs on Spotify"), .playLikedSongs)
    }

    func testPlaySongArtistAlbumPlaylist() {
        XCTAssertEqual(SpotifyCommandMatcher.match("Pune melodia Numb de la Linkin Park."), .play(query: "numb linkin park", kind: .track))
        XCTAssertEqual(SpotifyCommandMatcher.match("Macky, pune Bohemian Rhapsody pe Spotify"), .play(query: "bohemian rhapsody", kind: .track))
        XCTAssertEqual(SpotifyCommandMatcher.match("dă drumul la ceva de la Queen"), .play(query: "queen", kind: .artist))
        XCTAssertEqual(SpotifyCommandMatcher.match("pornește albumul Meteora pe Spotify"), .play(query: "meteora", kind: .album))
        XCTAssertEqual(SpotifyCommandMatcher.match("pune playlistul Chill Vibes"), .play(query: "chill vibes", kind: .playlist))
        XCTAssertEqual(SpotifyCommandMatcher.match("Pornește piesa Levitating"), .play(query: "levitating", kind: .track))
    }

    func testControlsAndResume() {
        XCTAssertEqual(SpotifyCommandMatcher.match("pune pauză la Spotify"), .pause)
        XCTAssertEqual(SpotifyCommandMatcher.match("următoarea melodie pe Spotify"), .nextTrack)
        XCTAssertEqual(SpotifyCommandMatcher.match("pune muzică"), .resume)
    }

    func testNotSpotify() {
        XCTAssertNil(SpotifyCommandMatcher.match("pornește Safari"))
        XCTAssertNil(SpotifyCommandMatcher.match("pune pauză"))
        XCTAssertNil(SpotifyCommandMatcher.match("unde e butonul de export?"))
        XCTAssertNil(SpotifyCommandMatcher.match("deschide Spotify"))
    }

    func testToolArguments() {
        XCTAssertEqual(SpotifyCommand(toolArgumentsJSON: #"{"action":"play","query":"Numb","kind":"track"}"#), .play(query: "Numb", kind: .track))
        XCTAssertEqual(SpotifyCommand(toolArgumentsJSON: #"{"action":"play_liked_songs"}"#), .playLikedSongs)
        XCTAssertNil(SpotifyCommand(toolArgumentsJSON: #"{"action":"play"}"#))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "s", name: "spotify", argumentsJSON: #"{"action":"next"}"#)), .spotify(.nextTrack))
    }

    func testHelpers() {
        let preferences = "language=\"ro\"\nautologin.canonical_username=\"darius123\"\nautologin.username=\"darius\"\n"
        XCTAssertEqual(SpotifyHelpers.username(fromPreferencesText: preferences), "darius123")
        XCTAssertEqual(SpotifyHelpers.likedSongsURI(username: "darius123"), "spotify:user:darius123:collection")
        XCTAssertTrue(SpotifyHelpers.nowPlaying(trackName: "Numb", artistName: "Linkin Park", albumName: "Meteora", matches: "numb linkin park"))
        XCTAssertFalse(SpotifyHelpers.nowPlaying(trackName: "Yellow", artistName: "Coldplay", albumName: "Parachutes", matches: "numb linkin park"))
        XCTAssertEqual(SpotifyHelpers.appleScriptString(#"say "hi""#), #""say \"hi\"""#)
    }
}
