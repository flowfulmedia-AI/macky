import Foundation

// MARK: - Zoom cloud recordings

/// Zoom's REST API, read-only, through a Server-to-Server OAuth app of the user's own Zoom account.
public enum ZoomAPI {
    public static func tokenURL(accountIdentifier: String) -> URL {
        var components = URLComponents(string: "https://zoom.us/oauth/token")!
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "account_credentials"),
            URLQueryItem(name: "account_id", value: accountIdentifier)
        ]
        return components.url!
    }

    /// "Basic base64(clientId:clientSecret)".
    public static func basicAuthorization(clientIdentifier: String, clientSecret: String) -> String {
        "Basic " + Data("\(clientIdentifier):\(clientSecret)".utf8).base64EncodedString()
    }

    public static func recordingsURL(userIdentifier: String, from: Date, to: Date, nextPageToken: String? = nil) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let user = userIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userIdentifier
        var components = URLComponents(string: "https://api.zoom.us/v2/users/\(user)/recordings")!
        components.queryItems = [
            URLQueryItem(name: "from", value: formatter.string(from: from)),
            URLQueryItem(name: "to", value: formatter.string(from: to)),
            URLQueryItem(name: "page_size", value: "30")
        ]
        if let nextPageToken, !nextPageToken.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "next_page_token", value: nextPageToken))
        }
        return components.url!
    }

    public struct RecordingFile: Equatable, Sendable {
        public var identifier: String
        public var fileType: String
        public var recordingType: String
        public var downloadURL: String
        public var status: String
        public var fileSize: Int
    }

    public struct Meeting: Equatable, Sendable {
        public var uuid: String
        public var topic: String
        public var startTime: Date?
        public var durationMinutes: Int
        public var files: [RecordingFile]

        public var transcriptFile: RecordingFile? {
            files.first { $0.fileType.uppercased() == "TRANSCRIPT" && $0.status.lowercased() == "completed" }
        }

        /// The smallest file that has the audio, for transcribing on the Mac when Zoom made no transcript.
        public var audioFile: RecordingFile? {
            files.filter { ["M4A", "MP4"].contains($0.fileType.uppercased()) && $0.status.lowercased() == "completed" }
                .min { first, second in
                    // Prefer audio-only, then the smallest video.
                    if (first.fileType.uppercased() == "M4A") != (second.fileType.uppercased() == "M4A") { return first.fileType.uppercased() == "M4A" }
                    return first.fileSize < second.fileSize
                }
        }

        public var isStillProcessing: Bool {
            files.contains { $0.status.lowercased() == "processing" }
        }
    }

    public static func parseRecordings(_ data: Data) -> (meetings: [Meeting], nextPageToken: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        let isoFormatter = ISO8601DateFormatter()
        let meetings = ((json["meetings"] as? [[String: Any]]) ?? []).compactMap { entry -> Meeting? in
            guard let uuid = entry["uuid"] as? String else { return nil }
            let files = ((entry["recording_files"] as? [[String: Any]]) ?? []).compactMap { file -> RecordingFile? in
                guard let downloadURL = file["download_url"] as? String else { return nil }
                return RecordingFile(
                    identifier: (file["id"] as? String) ?? UUID().uuidString,
                    fileType: (file["file_type"] as? String) ?? "",
                    recordingType: (file["recording_type"] as? String) ?? "",
                    downloadURL: downloadURL,
                    status: (file["status"] as? String) ?? "completed",
                    fileSize: OpenRouterStreamDecoder.integerValue(file["file_size"]) ?? 0
                )
            }
            return Meeting(
                uuid: uuid,
                topic: (entry["topic"] as? String) ?? "Meeting Zoom",
                startTime: (entry["start_time"] as? String).flatMap(isoFormatter.date(from:)),
                durationMinutes: OpenRouterStreamDecoder.integerValue(entry["duration"]) ?? 0,
                files: files
            )
        }
        let token = (json["next_page_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (meetings, token)
    }
}

// MARK: - Transcripts

public struct TranscriptLine: Equatable, Sendable {
    public var startSeconds: Double
    public var speaker: String?
    public var text: String

    public init(startSeconds: Double, speaker: String?, text: String) {
        self.startSeconds = startSeconds
        self.speaker = speaker
        self.text = text
    }
}

public enum TranscriptFormatter {
    /// Zoom's WebVTT transcript: numbered cues, "00:00:01.000 --> 00:00:04.500", then "Name: text".
    public static func parseWebVTT(_ text: String) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var currentStart: Double?
        for rawLine in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map({ String(String.UnicodeScalarView($0)) }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("-->") {
                currentStart = seconds(fromTimestamp: line.components(separatedBy: "-->")[0])
                continue
            }
            guard let start = currentStart, !line.isEmpty, line != "WEBVTT" else { continue }
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 60,
               !line[..<colon].contains(where: \.isNumber) || line[..<colon].contains(" ") {
                let speaker = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let spoken = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                lines.append(TranscriptLine(startSeconds: start, speaker: speaker.isEmpty ? nil : speaker, text: spoken))
            } else {
                lines.append(TranscriptLine(startSeconds: start, speaker: nil, text: line))
            }
            currentStart = nil
        }
        return mergingConsecutiveSpeakers(lines)
    }

    /// "00:01:02.500" or "01:02.500" → seconds.
    static func seconds(fromTimestamp text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).components(separatedBy: ":").compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// One paragraph per turn instead of one line per caption.
    public static func mergingConsecutiveSpeakers(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var merged: [TranscriptLine] = []
        for line in lines where !line.text.isEmpty {
            if let last = merged.last, last.speaker == line.speaker, line.startSeconds - last.startSeconds < 90 {
                merged[merged.count - 1].text += " " + line.text
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    public static func plainText(_ lines: [TranscriptLine]) -> String {
        lines.map { line in
            "[\(clock(line.startSeconds))] " + (line.speaker.map { "\($0): " } ?? "") + line.text
        }.joined(separator: "\n")
    }

    public static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Meeting notes

/// What the model writes about a meeting.
public struct MeetingNotes: Equatable, Sendable {
    public struct ActionItem: Equatable, Sendable {
        public var owner: String?
        public var task: String
        public var due: String?
    }

    public var title: String
    public var summary: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var participants: [String]
}

public enum MeetingNotesBuilder {
    /// Long transcripts are cut (middle first) so the summary request stays affordable.
    public static let maximumTranscriptCharacters = 80_000

    public static func messages(topic: String, date: String, transcript: String) -> [ChatMessage] {
        let system = """
        You write meeting notes in Romanian for the user, from a meeting transcript. Be concrete and faithful: \
        use names, numbers and dates exactly as said; never invent. Answer ONLY with JSON:
        {"title": "short descriptive title",
         "participants": ["names mentioned or speaking"],
         "summary": "5-10 sentences: purpose, what was discussed, outcome",
         "decisions": ["each decision taken"],
         "action_items": [{"owner": "who, or null", "task": "what, starting with a verb", "due": "when, or null"}]}
        """
        var shownTranscript = transcript
        if shownTranscript.count > maximumTranscriptCharacters {
            let half = maximumTranscriptCharacters / 2
            shownTranscript = String(transcript.prefix(half)) + "\n[… middle of the meeting omitted …]\n" + String(transcript.suffix(half))
        }
        let user = "Meeting: \(topic)\nDate: \(date)\n\nTranscript:\n\(shownTranscript)"
        return [ChatMessage(role: .system, text: system), ChatMessage(role: .user, text: user)]
    }

    public static func parse(_ responseText: String, fallbackTitle: String) -> MeetingNotes {
        let object = MemoryCurator.jsonObject(in: responseText) ?? [:]
        func strings(_ key: String) -> [String] {
            ((object[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let actionItems = ((object["action_items"] as? [[String: Any]]) ?? []).compactMap { entry -> MeetingNotes.ActionItem? in
            guard let task = MemoryCurator.cleaned(entry["task"]) else { return nil }
            return MeetingNotes.ActionItem(owner: MemoryCurator.cleaned(entry["owner"]), task: task, due: MemoryCurator.cleaned(entry["due"]))
        }
        return MeetingNotes(
            title: MemoryCurator.cleaned(object["title"]) ?? fallbackTitle,
            summary: MemoryCurator.cleaned(object["summary"]) ?? (object.isEmpty ? responseText.trimmingCharacters(in: .whitespacesAndNewlines) : ""),
            decisions: strings("decisions"),
            actionItems: actionItems,
            participants: strings("participants")
        )
    }

    /// The Google Doc, as HTML (Drive converts it with headings and lists).
    public static func html(notes: MeetingNotes, topic: String, date: String, durationMinutes: Int, transcriptLines: [TranscriptLine]) -> String {
        func escape(_ text: String) -> String { EdgeTTSProtocol.escapeXML(text) }
        var html = "<html><head><meta charset=\"utf-8\"></head><body>"
        html += "<h1>\(escape(notes.title))</h1>"
        var details = ["<b>Data:</b> \(escape(date))", "<b>Meeting Zoom:</b> \(escape(topic))"]
        if durationMinutes > 0 { details.append("<b>Durată:</b> \(durationMinutes) min") }
        if !notes.participants.isEmpty { details.append("<b>Participanți:</b> \(escape(notes.participants.joined(separator: ", ")))") }
        html += "<p>" + details.joined(separator: "<br>") + "</p>"
        html += "<h2>Rezumat</h2><p>\(escape(notes.summary))</p>"
        if !notes.decisions.isEmpty {
            html += "<h2>Decizii</h2><ul>" + notes.decisions.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
        }
        if !notes.actionItems.isEmpty {
            html += "<h2>Acțiuni</h2><ul>" + notes.actionItems.map { item in
                var line = escape(item.task)
                if let owner = item.owner { line = "<b>\(escape(owner)):</b> " + line }
                if let due = item.due { line += " <i>(\(escape(due)))</i>" }
                return "<li>\(line)</li>"
            }.joined() + "</ul>"
        }
        html += "<h2>Transcriere</h2>"
        for line in transcriptLines {
            let speaker = line.speaker.map { "<b>\(escape($0)):</b> " } ?? ""
            html += "<p><span style=\"color:#888\">[\(TranscriptFormatter.clock(line.startSeconds))]</span> \(speaker)\(escape(line.text))</p>"
        }
        return html + "</body></html>"
    }

    /// Plain Markdown copy saved on the Mac.
    public static func markdown(notes: MeetingNotes, topic: String, date: String, transcriptLines: [TranscriptLine]) -> String {
        var text = "# \(notes.title)\n\nData: \(date) · Meeting Zoom: \(topic)\n"
        if !notes.participants.isEmpty { text += "Participanți: \(notes.participants.joined(separator: ", "))\n" }
        text += "\n## Rezumat\n\n\(notes.summary)\n"
        if !notes.decisions.isEmpty { text += "\n## Decizii\n\n" + notes.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !notes.actionItems.isEmpty {
            let itemLines = notes.actionItems.map { item -> String in
                let owner = item.owner.map { "**\($0):** " } ?? ""
                let due = item.due.map { " (\($0))" } ?? ""
                return "- \(owner)\(item.task)\(due)"
            }
            text += "\n## Acțiuni\n\n" + itemLines.joined(separator: "\n") + "\n"
        }
        return text + "\n## Transcriere\n\n" + TranscriptFormatter.plainText(transcriptLines) + "\n"
    }
}

// MARK: - Google Drive upload

public enum DriveUpload {
    public static let uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true&fields=id,webViewLink")!
    public static let filesURL = URL(string: "https://www.googleapis.com/drive/v3/files?supportsAllDrives=true&fields=id,webViewLink")!

    /// multipart/related body: JSON metadata, then the content. Returns the body and its Content-Type.
    public static func multipartBody(name: String, targetMimeType: String, parentFolderIdentifier: String?,
                                     content: Data, contentMimeType: String, boundary: String = "macky-\(UUID().uuidString)") -> (body: Data, contentType: String) {
        var metadata: [String: Any] = ["name": name, "mimeType": targetMimeType]
        if let parentFolderIdentifier { metadata["parents"] = [parentFolderIdentifier] }
        let metadataData = (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data()
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadataData)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(contentMimeType)\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/related; boundary=\(boundary)")
    }

    public static func folderMetadata(name: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["name": name, "mimeType": "application/vnd.google-apps.folder"], options: [.sortedKeys])) ?? Data()
    }

    public static func parseCreatedFile(_ data: Data) -> (identifier: String, link: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let identifier = json["id"] as? String else { return nil }
        return (identifier, json["webViewLink"] as? String)
    }
}

// MARK: - "Fă task din asta"

public enum TaskCaptureIntent {
    static let phrases = [
        "fa task din asta", "fa un task din asta", "fa-mi task din asta", "fa-mi un task din asta", "fa task din ce", "task din asta",
        "pune asta ca task", "pune asta in taskuri", "pune asta la taskuri", "adauga asta la taskuri", "adauga asta ca task",
        "creeaza task din asta", "creeaza un task din asta", "noteaza asta ca task", "fa din asta un task", "make this a task",
        "make a task from this", "add this as a task"
    ]

    public static func matches(_ question: String) -> Bool {
        let folded = QuickCommandMatcher.normalize(question).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return phrases.contains { folded.contains($0) }
    }

    /// Added to the request so the model builds one good task from what the user is looking at.
    public static func instruction(taskAppNames: [String]) -> String {
        let destination = taskAppNames.isEmpty
            ? "Create it with create_reminder."
            : "Create it in \(taskAppNames.joined(separator: " or ")) with its task-creation tool (fall back to create_reminder only if that fails)."
        return """
        The user wants ONE task made from what they are looking at right now (the screenshot, the selected text, the open page or email). \
        Title: short, starts with a verb, says what to do. In the description or notes, put the useful details and the source: \
        the page URL, or the email's sender and subject, or the app and document. Fill in client or project and due date only when they are clear. \
        \(destination) Then confirm in a few words, e.g. "Gata, am pus taskul."
        """
    }
}
