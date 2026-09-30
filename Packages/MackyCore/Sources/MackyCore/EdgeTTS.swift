import Foundation

/// The free neural voices of Microsoft Edge's "Read aloud" (e.g. ro-RO-AlinaNeural), spoken over a WebSocket.
/// This file builds and parses the protocol messages; the app opens the connection and plays the audio.
public enum EdgeTTSProtocol {
    public static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    public static let secMSGECVersion = "1-143.0.3650.75"
    public static let origin = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"

    public struct Voice: Equatable, Sendable, Identifiable {
        public var id: String
        public var displayName: String
        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }
    }

    public static let romanianVoices = [
        Voice(id: "ro-RO-AlinaNeural", displayName: "Alina (feminin)"),
        Voice(id: "ro-RO-EmilNeural", displayName: "Emil (masculin)")
    ]
    public static let englishVoices = [
        Voice(id: "en-US-AvaMultilingualNeural", displayName: "Ava (feminin)"),
        Voice(id: "en-US-AndrewMultilingualNeural", displayName: "Andrew (masculin)")
    ]

    /// Text hashed (SHA-256, uppercase hex) into the Sec-MS-GEC parameter: Windows file time in 100 ns ticks,
    /// rounded down to 5 minutes, followed by the client token.
    public static func secMSGECInput(now: Date) -> String {
        var seconds = now.timeIntervalSince1970 + 11_644_473_600
        seconds -= seconds.truncatingRemainder(dividingBy: 300)
        let ticks = UInt64(seconds) * 10_000_000
        return "\(ticks)\(trustedClientToken)"
    }

    public static func webSocketURL(secMSGEC: String, connectionIdentifier: String) -> URL {
        var components = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionIdentifier),
            URLQueryItem(name: "Sec-MS-GEC", value: secMSGEC),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: secMSGECVersion)
        ]
        return components.url!
    }

    /// A random 32-character uppercase hex id (cookie and request ids).
    public static func randomHexIdentifier(uppercase: Bool = false) -> String {
        let text = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return uppercase ? text.uppercased() : text.lowercased()
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: date)
    }

    public static func configurationMessage(now: Date) -> String {
        "X-Timestamp:\(timestamp(now))\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
            + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
            + "\r\n"
    }

    /// `rate` and `pitch` are relative changes, e.g. +10 means 10% faster.
    public static func ssmlMessage(text: String, voice: String, ratePercent: Int, pitchHertz: Int, requestIdentifier: String, now: Date) -> String {
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(voice)'><prosody pitch='\(signed(pitchHertz))Hz' rate='\(signed(ratePercent))%' volume='+0%'>"
            + escapeXML(text)
            + "</prosody></voice></speak>"
        return "X-RequestId:\(requestIdentifier)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp(now))Z\r\nPath:ssml\r\n\r\n" + ssml
    }

    static func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }

    public static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// The MP3 bytes inside a binary frame, or nil for frames without audio.
    /// Frame layout: 2-byte big-endian header length, the text headers, then the audio.
    public static func audioPayload(fromBinaryFrame frame: Data) -> Data? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 2 else { return nil }
        let headerLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + headerLength else { return nil }
        let headerText = String(decoding: bytes[2..<(2 + headerLength)], as: UTF8.self)
        guard headerText.contains("Path:audio") else { return nil }
        let audio = Data(bytes[(2 + headerLength)...])
        return audio.isEmpty ? nil : audio
    }

    /// Whether a text frame says the audio for the request is complete.
    public static func isTurnEnd(textFrame: String) -> Bool {
        textFrame.contains("Path:turn.end")
    }
}
