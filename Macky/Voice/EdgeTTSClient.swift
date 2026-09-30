import CryptoKit
import Foundation
import MackyCore

/// Fetches speech from Microsoft Edge's free neural voices ("Read aloud"). Each call returns the MP3
/// for one sentence, or nil when the service cannot be reached in time (Macky then uses the Mac voice).
final class EdgeTTSClient: @unchecked Sendable {
    private let urlSession: URLSession
    private let cookieIdentifier = EdgeTTSProtocol.randomHexIdentifier(uppercase: true)
    private static let timeoutInNanoseconds: UInt64 = 8_000_000_000

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        urlSession = URLSession(configuration: configuration)
    }

    func synthesize(_ text: String, voice: String, ratePercent: Int) async -> Data? {
        let now = Date()
        let secMSGEC = SHA256.hash(data: Data(EdgeTTSProtocol.secMSGECInput(now: now).utf8))
            .map { String(format: "%02X", $0) }
            .joined()
        var request = URLRequest(url: EdgeTTSProtocol.webSocketURL(secMSGEC: secMSGEC, connectionIdentifier: EdgeTTSProtocol.randomHexIdentifier()))
        request.setValue(EdgeTTSProtocol.origin, forHTTPHeaderField: "Origin")
        request.setValue(EdgeTTSProtocol.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(cookieIdentifier);", forHTTPHeaderField: "Cookie")

        let webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask.resume()
        let result = await withTaskGroup(of: Data?.self) { group -> Data? in
            group.addTask {
                await Self.exchange(on: webSocketTask, text: text, voice: voice, ratePercent: ratePercent, now: now)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.timeoutInNanoseconds)
                return nil
            }
            let firstResult = await group.next() ?? nil
            // Closing the socket also ends a receive that is still waiting.
            webSocketTask.cancel(with: .normalClosure, reason: nil)
            group.cancelAll()
            return firstResult
        }
        return result
    }

    private static func exchange(on webSocketTask: URLSessionWebSocketTask, text: String, voice: String, ratePercent: Int, now: Date) async -> Data? {
        do {
            try await webSocketTask.send(.string(EdgeTTSProtocol.configurationMessage(now: now)))
            try await webSocketTask.send(.string(EdgeTTSProtocol.ssmlMessage(
                text: text, voice: voice, ratePercent: ratePercent, pitchHertz: 0,
                requestIdentifier: EdgeTTSProtocol.randomHexIdentifier(), now: now
            )))
            var audio = Data()
            while true {
                switch try await webSocketTask.receive() {
                case .data(let frame):
                    if let payload = EdgeTTSProtocol.audioPayload(fromBinaryFrame: frame) { audio.append(payload) }
                case .string(let textFrame):
                    if EdgeTTSProtocol.isTurnEnd(textFrame: textFrame) { return audio.isEmpty ? nil : audio }
                @unknown default:
                    break
                }
            }
        } catch {
            return nil
        }
    }
}
