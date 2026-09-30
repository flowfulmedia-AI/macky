import Foundation
import MackyCore

/// A Zoom meeting Macky already handled, shown in Settings → Conexiuni.
struct ProcessedZoomMeeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case saved, failed, noAudio }
    var id: String            // Zoom meeting UUID
    var topic: String
    var date: Date
    var status: Status
    var documentLink: String?
    var localPath: String?
    var message: String?
}

/// Finished meeting notes, handed to the session (history, memory, optional tasks).
struct SavedMeetingNotes {
    var topic: String
    var notes: MeetingNotes
    var documentLink: String
}

/// Watches the user's Zoom cloud recordings (Server-to-Server OAuth app of their own account). For every new
/// meeting: takes Zoom's transcript (or transcribes the audio on the Mac), writes notes with the fast model,
/// saves them as a Google Doc in a Drive folder and as Markdown in ~/Documents/Macky/Meetinguri.
@MainActor
final class ZoomMeetingsManager: ObservableObject {
    private static let keychainService = "com.flowfulmedia.macky.zoom"
    private static let processedFileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("zoom-meetings.json")
    private static let checkInterval: TimeInterval = 15 * 60
    /// Without a Zoom transcript, wait this long after the meeting before transcribing the audio ourselves.
    private static let transcriptGracePeriod: TimeInterval = 2 * 3600

    @Published private(set) var hasCredentials: Bool
    @Published private(set) var processedMeetings: [ProcessedZoomMeeting] = []
    @Published private(set) var statusText: String?
    @Published private(set) var isChecking = false
    @Published var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: "zoomEnabled"); if isEnabled { scheduleChecks() } } }
    @Published var driveFolderName: String { didSet { UserDefaults.standard.set(driveFolderName, forKey: "zoomDriveFolderName") } }
    @Published var userEmail: String { didSet { UserDefaults.standard.set(userEmail, forKey: "zoomUserEmail") } }
    /// Also put the user's own action items into their task app (e.g. Flowts).
    @Published var createsTasks: Bool { didSet { UserDefaults.standard.set(createsTasks, forKey: "zoomCreatesTasks") } }

    /// Transcribes an audio file on the Mac (Whisper); provided by the session, which owns the model.
    var transcribeAudioFile: ((URL) async throws -> [TranscriptLine])?
    var onMeetingSaved: ((SavedMeetingNotes) -> Void)?

    private let settings: AppSettings
    private let apiKeyStore: OpenRouterAPIKeyStore
    private let openRouterClient: OpenRouterClient
    private let googleAccountManager: GoogleAccountManager
    private var accessToken: String?
    private var accessTokenExpiryDate: Date?
    private var timer: Timer?
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: configuration)
    }()

    init(settings: AppSettings, apiKeyStore: OpenRouterAPIKeyStore, openRouterClient: OpenRouterClient, googleAccountManager: GoogleAccountManager) {
        self.settings = settings
        self.apiKeyStore = apiKeyStore
        self.openRouterClient = openRouterClient
        self.googleAccountManager = googleAccountManager
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["zoomEnabled": true, "zoomDriveFolderName": "Macky – Meetinguri Zoom", "zoomCreatesTasks": false])
        isEnabled = defaults.bool(forKey: "zoomEnabled")
        driveFolderName = defaults.string(forKey: "zoomDriveFolderName") ?? "Macky – Meetinguri Zoom"
        userEmail = defaults.string(forKey: "zoomUserEmail") ?? ""
        createsTasks = defaults.bool(forKey: "zoomCreatesTasks")
        hasCredentials = [Self.credential("account-id"), Self.credential("client-id"), Self.credential("client-secret")].allSatisfy { !($0 ?? "").isEmpty }
        loadProcessedMeetings()
    }

    // MARK: Credentials

    private static func credential(_ account: String) -> String? {
        KeychainStore.readString(service: keychainService, account: account)
    }

    func saveCredentials(accountIdentifier: String, clientIdentifier: String, clientSecret: String) throws {
        let values = [("account-id", accountIdentifier), ("client-id", clientIdentifier), ("client-secret", clientSecret)]
        for (account, value) in values {
            try KeychainStore.writeString(value.trimmingCharacters(in: .whitespacesAndNewlines), service: Self.keychainService, account: account)
        }
        accessToken = nil
        hasCredentials = values.allSatisfy { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Start with the meetings of the last two days, not the whole archive.
        if UserDefaults.standard.object(forKey: "zoomProcessFromDate") == nil {
            UserDefaults.standard.set(Date().addingTimeInterval(-2 * 24 * 3600), forKey: "zoomProcessFromDate")
        }
        scheduleChecks()
    }

    func removeCredentials() {
        for account in ["account-id", "client-id", "client-secret"] {
            KeychainStore.delete(service: Self.keychainService, account: account)
        }
        accessToken = nil
        hasCredentials = false
        statusText = "Deconectat de la Zoom."
    }

    // MARK: Scheduling

    func start() {
        scheduleChecks()
    }

    private func scheduleChecks() {
        timer?.invalidate()
        guard isEnabled, hasCredentials else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForNewMeetings() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await checkForNewMeetings()
        }
    }

    // MARK: Processing

    func checkForNewMeetings() async {
        guard isEnabled, hasCredentials, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        statusText = "Verific înregistrările Zoom…"
        do {
            let token = try await validAccessToken()
            let processFromDate = (UserDefaults.standard.object(forKey: "zoomProcessFromDate") as? Date) ?? Date().addingTimeInterval(-2 * 24 * 3600)
            let fromDate = max(processFromDate, Date().addingTimeInterval(-30 * 24 * 3600))
            let meetings = try await listRecordings(token: token, from: fromDate)
            let handledIdentifiers = Set(processedMeetings.map(\.id))
            var savedCount = 0
            for meeting in meetings.sorted(by: { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) })
            where !handledIdentifiers.contains(meeting.uuid) && (meeting.startTime ?? .distantFuture) >= processFromDate && !meeting.isStillProcessing {
                if try await process(meeting, token: token) { savedCount += 1 }
            }
            let time = Date().formatted(date: .omitted, time: .shortened)
            statusText = savedCount > 0 ? "Am salvat \(savedCount) meeting(uri) în Drive (\(time))." : "Nimic nou de procesat (verificat la \(time))."
        } catch {
            statusText = "Eroare Zoom: \(error.localizedDescription)"
        }
    }

    /// Returns true when the meeting was saved; false when it should wait (Zoom is still making the transcript).
    private func process(_ meeting: ZoomAPI.Meeting, token: String) async throws -> Bool {
        let meetingDate = meeting.startTime ?? Date()
        var transcriptLines: [TranscriptLine] = []
        if let transcriptFile = meeting.transcriptFile {
            statusText = "Descarc transcrierea: \(meeting.topic)…"
            let data = try await download(transcriptFile, token: token)
            transcriptLines = TranscriptFormatter.parseWebVTT(String(decoding: data, as: UTF8.self))
        } else if let audioFile = meeting.audioFile {
            let meetingEnd = meetingDate.addingTimeInterval(Double(meeting.durationMinutes) * 60)
            guard Date().timeIntervalSince(meetingEnd) > Self.transcriptGracePeriod else { return false }
            guard let transcribeAudioFile else { return false }
            statusText = "Transcriu pe Mac: \(meeting.topic)…"
            let audioData = try await download(audioFile, token: token)
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-\(audioFile.identifier).\(audioFile.fileType.lowercased())")
            try audioData.write(to: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            transcriptLines = try await transcribeAudioFile(fileURL)
        }
        guard !transcriptLines.isEmpty else {
            record(ProcessedZoomMeeting(id: meeting.uuid, topic: meeting.topic, date: meetingDate, status: .noAudio,
                                        message: "Înregistrarea nu are audio sau transcriere."))
            return false
        }

        statusText = "Scriu notițele: \(meeting.topic)…"
        let dateText = meetingDate.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Locale(identifier: "ro_RO")))
        let transcriptText = TranscriptFormatter.plainText(transcriptLines)
        let responseText = (try? await summarize(topic: meeting.topic, date: dateText, transcript: transcriptText)) ?? ""
        let notes = MeetingNotesBuilder.parse(responseText, fallbackTitle: meeting.topic)

        let localPath = saveLocally(notes: notes, topic: meeting.topic, date: meetingDate, dateText: dateText, lines: transcriptLines)
        do {
            statusText = "Urc în Drive: \(notes.title)…"
            let documentName = "\(meetingDate.formatted(.iso8601.year().month().day())) · \(notes.title)"
            let link = try await googleAccountManager.uploadGoogleDoc(
                named: documentName,
                html: MeetingNotesBuilder.html(notes: notes, topic: meeting.topic, date: dateText, durationMinutes: meeting.durationMinutes, transcriptLines: transcriptLines),
                folderName: driveFolderName
            )
            record(ProcessedZoomMeeting(id: meeting.uuid, topic: notes.title, date: meetingDate, status: .saved, documentLink: link, localPath: localPath))
            onMeetingSaved?(SavedMeetingNotes(topic: meeting.topic, notes: notes, documentLink: link))
            return true
        } catch {
            // Kept on the Mac; tried again on the next check.
            statusText = "Nu am putut urca în Drive: \(error.localizedDescription) (copie salvată în \(localPath ?? "Documents/Macky"))"
            throw error
        }
    }

    /// Forgets a meeting so the next check handles it again.
    func retry(_ identifier: String) {
        processedMeetings.removeAll { $0.id == identifier }
        saveProcessedMeetings()
        Task { await checkForNewMeetings() }
    }

    private func summarize(topic: String, date: String, transcript: String) async throws -> String {
        guard let apiKey = apiKeyStore.apiKey(), !apiKey.isEmpty else { return "" }
        let modelIdentifier = settings.fastModelIdentifier.isEmpty ? settings.powerfulModelIdentifier : settings.fastModelIdentifier
        let messages = MeetingNotesBuilder.messages(topic: topic, date: date, transcript: transcript)
        func body(disableReasoning: Bool) throws -> Data {
            try OpenRouterRequestBuilder.makeChatCompletionBody(
                modelIdentifier: modelIdentifier, messages: messages, tools: [], coordinateConvention: .imagePixels,
                disableReasoning: disableReasoning, maximumResponseTokens: 3000
            )
        }
        do {
            return try await openRouterClient.collectChatCompletion(requestBody: body(disableReasoning: settings.shouldDisableReasoning(forModelIdentifier: modelIdentifier)), apiKey: apiKey, purpose: .meetings).text
        } catch let apiError as OpenRouterAPIError where apiError.httpStatusCode == 400 {
            return try await openRouterClient.collectChatCompletion(requestBody: body(disableReasoning: false), apiKey: apiKey, purpose: .meetings).text
        }
    }

    private func saveLocally(notes: MeetingNotes, topic: String, date: Date, dateText: String, lines: [TranscriptLine]) -> String? {
        let folderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Macky/Meetinguri", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let name = HTMLTextExtractor.sanitizedFileName("\(date.formatted(.iso8601.year().month().day())) \(notes.title).md")
        let fileURL = folderURL.appendingPathComponent(name)
        let markdown = MeetingNotesBuilder.markdown(notes: notes, topic: topic, date: dateText, transcriptLines: lines)
        return (try? markdown.write(to: fileURL, atomically: true, encoding: .utf8)) != nil ? fileURL.path : nil
    }

    // MARK: Zoom API

    /// Checks the credentials by getting a token; used by the "Testează" button.
    func testConnection() async {
        do {
            accessToken = nil
            let token = try await validAccessToken()
            let meetings = try await listRecordings(token: token, from: Date().addingTimeInterval(-30 * 24 * 3600))
            statusText = "Conectat la Zoom · \(meetings.count) înregistrări cloud în ultimele 30 de zile."
        } catch {
            statusText = "Eroare Zoom: \(error.localizedDescription)"
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, let accessTokenExpiryDate, Date() < accessTokenExpiryDate { return accessToken }
        guard let accountIdentifier = Self.credential("account-id"), let clientIdentifier = Self.credential("client-id"),
              let clientSecret = Self.credential("client-secret") else {
            throw MCPProtocol.RPCError(message: "Adaugă datele aplicației Zoom în Setări → Conexiuni.")
        }
        var request = URLRequest(url: ZoomAPI.tokenURL(accountIdentifier: accountIdentifier))
        request.httpMethod = "POST"
        request.setValue(ZoomAPI.basicAuthorization(clientIdentifier: clientIdentifier, clientSecret: clientSecret), forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["reason"] ?? $0["error"]) as? String } ?? ""
            throw MCPProtocol.RPCError(message: "Zoom a refuzat datele aplicației. Verifică Account ID, Client ID, Client Secret și că aplicația e activată. \(reason)")
        }
        let tokens = try GoogleOAuth.parseTokenResponse(data)
        accessToken = tokens.accessToken
        accessTokenExpiryDate = Date().addingTimeInterval(tokens.expiresInSeconds - 60)
        return tokens.accessToken
    }

    private func listRecordings(token: String, from fromDate: Date) async throws -> [ZoomAPI.Meeting] {
        let userIdentifier = userEmail.trimmingCharacters(in: .whitespaces).isEmpty ? "me" : userEmail.trimmingCharacters(in: .whitespaces)
        var meetings: [ZoomAPI.Meeting] = []
        var pageToken: String?
        repeat {
            var request = URLRequest(url: ZoomAPI.recordingsURL(userIdentifier: userIdentifier, from: fromDate, to: Date().addingTimeInterval(24 * 3600), nextPageToken: pageToken))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["message"] as? String } ?? "HTTP \(statusCode)"
                throw MCPProtocol.RPCError(message: "Zoom: \(message)" + (statusCode == 400 || statusCode == 404 ? " (încearcă să completezi emailul contului Zoom)" : ""))
            }
            let page = ZoomAPI.parseRecordings(data)
            meetings += page.meetings
            pageToken = page.nextPageToken
        } while pageToken != nil && meetings.count < 300
        return meetings
    }

    private func download(_ file: ZoomAPI.RecordingFile, token: String) async throws -> Data {
        guard let url = URL(string: file.downloadURL) else { throw MCPProtocol.RPCError(message: "Adresă de descărcare invalidă.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw MCPProtocol.RPCError(message: "Zoom nu a permis descărcarea (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Verifică permisiunile aplicației.")
        }
        return data
    }

    // MARK: Persistence

    private func record(_ meeting: ProcessedZoomMeeting) {
        processedMeetings.removeAll { $0.id == meeting.id }
        processedMeetings.insert(meeting, at: 0)
        if processedMeetings.count > 300 { processedMeetings.removeLast(processedMeetings.count - 300) }
        saveProcessedMeetings()
    }

    private func loadProcessedMeetings() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.processedFileURL),
           let meetings = try? decoder.decode([ProcessedZoomMeeting].self, from: data) {
            processedMeetings = meetings
        }
    }

    private func saveProcessedMeetings() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(processedMeetings) {
            try? data.write(to: Self.processedFileURL, options: .atomic)
        }
    }
}
