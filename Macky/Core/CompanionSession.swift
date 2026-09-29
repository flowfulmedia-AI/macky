import AppKit
import AVFoundation
import MackyCore

/// The central state machine. Runs one interaction at a time:
/// hold hotkey → record → release → screenshot + transcribe → ask the model (streaming)
/// → speak sentence by sentence → fly the cursor to what the model pointed at.
/// Pressing the hotkey again at any moment interrupts whatever is happening.
@MainActor
final class CompanionSession: ObservableObject {
    @Published private(set) var state: CompanionState = .idle
    @Published private(set) var lastQuestionText = ""
    @Published private(set) var lastAnswerText = ""
    @Published private(set) var lastAnswerModelIdentifier = ""
    @Published private(set) var costTracker = SessionCostTracker()
    /// Non-nil while the transcription model is downloading/loading, or when it failed to load.
    @Published private(set) var transcriberStatusText: String?

    private let settings: AppSettings
    private let apiKeyStore: OpenRouterAPIKeyStore
    private let modelCatalogStore: ModelCatalogStore
    private let overlayController: CompanionOverlayController
    private let audioRecorder = AudioRecorder()
    private let speechSpeaker = SpeechSpeaker()
    private let screenCaptureService = ScreenCaptureService()
    private let accessibilityInspector = AccessibilityInspector()
    private let openRouterClient: OpenRouterClient
    private let dictationTextInserter = DictationTextInserter()

    private var transcriber: SpeechTranscriber?
    private var transcriberConfigurationKey = ""
    private var conversationHistory = ConversationHistory()

    /// Every interaction gets a new identifier; async work checks it so an interrupted
    /// interaction can never update the UI or speak after a newer one started.
    private var currentInteractionIdentifier = UUID()
    private var currentInteractionTask: Task<Void, Never>?
    private var activeRecordingPurpose: HotkeyAction?
    private var isAnswerStreamComplete = false

    private var pointingWatchTimer: Timer?
    private var pointingClickMonitor: Any?

    private static let minimumRecordingDurationInSeconds = 0.3
    private static let maximumPointingSteps = 5

    init(settings: AppSettings, apiKeyStore: OpenRouterAPIKeyStore, modelCatalogStore: ModelCatalogStore,
         overlayController: CompanionOverlayController, openRouterClient: OpenRouterClient) {
        self.settings = settings
        self.apiKeyStore = apiKeyStore
        self.modelCatalogStore = modelCatalogStore
        self.overlayController = overlayController
        self.openRouterClient = openRouterClient

        audioRecorder.onAudioLevel = { [weak overlayController] audioLevel in
            overlayController?.setAudioLevel(audioLevel)
        }
        speechSpeaker.onAllSpeechFinished = { [weak self] in
            self?.speechQueueDrained()
        }
    }

    // MARK: Public entry points

    func handle(_ hotkeyEvent: HotkeyEvent) {
        switch hotkeyEvent {
        case .pressed(let action):
            startListening(for: action)
        case .released(let action):
            guard activeRecordingPurpose == action else { return }
            finishListening()
        case .cancelled(let action):
            guard activeRecordingPurpose == action else { return }
            cancelListening()
        }
    }

    /// Question typed in the menu bar panel instead of spoken.
    func ask(typedQuestion: String) {
        let question = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        stopEverything()
        let interactionIdentifier = startNewInteraction()
        overlayController.beginInteraction(activity: .thinking)
        state = .thinking
        currentInteractionTask = Task {
            let frontmostApplication = accessibilityInspector.frontmostApplicationSnapshot()
            let capturedScreens = await captureScreensForQuestion()
            guard isCurrent(interactionIdentifier) else { return }
            await answer(question: question, capturedScreens: capturedScreens, frontmostApplication: frontmostApplication, interactionIdentifier: interactionIdentifier)
        }
    }

    func stopEverything() {
        currentInteractionIdentifier = UUID()
        currentInteractionTask?.cancel()
        currentInteractionTask = nil
        if audioRecorder.isRecording { _ = audioRecorder.stopRecording() }
        activeRecordingPurpose = nil
        speechSpeaker.stopSpeaking()
        stopWatchingPointing()
        overlayController.hideImmediately()
        state = .idle
    }

    /// Plays a sample sentence with the current voice settings.
    func previewVoice() {
        speechSpeaker.stopSpeaking()
        let sampleSentence = settings.responseLanguage == .english
            ? "Hi, I'm Macky. Hold the shortcut and ask me anything about your screen."
            : "Salut, sunt Macky. Ține apăsat și întreabă-mă orice despre ce vezi pe ecran."
        speechSpeaker.speak(sampleSentence, voiceIdentifier: settings.speechVoiceIdentifier,
                            languageCode: settings.responseLanguage.transcriptionLanguageCode, rateMultiplier: settings.speechRateMultiplier)
    }

    func forgetConversation() {
        conversationHistory.clear()
        lastQuestionText = ""
        lastAnswerText = ""
    }

    /// Creates (or recreates after a settings change) the speech-to-text engine and warms it up.
    func prepareTranscriber() {
        let configurationKey = "\(settings.transcriptionEngine.rawValue)|\(settings.whisperModelVariant.rawValue)"
        guard configurationKey != transcriberConfigurationKey || transcriber == nil else { return }
        transcriberConfigurationKey = configurationKey

        let newTranscriber: SpeechTranscriber
        switch settings.transcriptionEngine {
        case .whisperKit:
            newTranscriber = WhisperKitTranscriber(modelVariant: settings.whisperModelVariant.rawValue)
            transcriberStatusText = "Se pregătește modelul Whisper (prima dată se descarcă, poate dura câteva minute)…"
        case .appleSpeech:
            newTranscriber = AppleSpeechTranscriber()
            transcriberStatusText = nil
        }
        transcriber = newTranscriber

        Task {
            do {
                try await newTranscriber.prepare()
                if transcriberConfigurationKey == configurationKey { transcriberStatusText = nil }
            } catch {
                if transcriberConfigurationKey == configurationKey {
                    transcriberStatusText = "Transcrierea nu e disponibilă: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Listening

    private func startListening(for purpose: HotkeyAction) {
        stopEverything()
        guard ensureMicrophoneAccess() else { return }
        do {
            try audioRecorder.startRecording()
        } catch {
            _ = startNewInteraction()
            fail(with: "Nu pot porni microfonul: \(error.localizedDescription)")
            return
        }
        _ = startNewInteraction()
        activeRecordingPurpose = purpose
        state = .listening
        overlayController.beginInteraction(activity: purpose == .dictate ? .dictating : .listening)
    }

    private func finishListening() {
        guard let purpose = activeRecordingPurpose else { return }
        activeRecordingPurpose = nil
        let recordedAudio = audioRecorder.stopRecording()
        let interactionIdentifier = currentInteractionIdentifier

        guard recordedAudio.durationInSeconds >= Self.minimumRecordingDurationInSeconds else {
            state = .idle
            overlayController.hideImmediately()
            return
        }

        state = .transcribing
        overlayController.setActivity(.thinking)

        currentInteractionTask = Task {
            switch purpose {
            case .talk:
                // The screen is captured right at release, while the user still looks at what they asked about.
                let frontmostApplication = accessibilityInspector.frontmostApplicationSnapshot()
                async let capturedScreensTask = captureScreensForQuestion()
                let transcript = await transcribe(recordedAudio, interactionIdentifier: interactionIdentifier)
                let capturedScreens = await capturedScreensTask
                guard isCurrent(interactionIdentifier), let transcript else { return }
                await answer(question: transcript, capturedScreens: capturedScreens, frontmostApplication: frontmostApplication, interactionIdentifier: interactionIdentifier)
            case .dictate:
                guard let transcript = await transcribe(recordedAudio, interactionIdentifier: interactionIdentifier),
                      isCurrent(interactionIdentifier) else { return }
                dictationTextInserter.insert(transcript)
                overlayController.setBubbleText(transcript)
                state = .idle
                overlayController.endInteraction(afterDelay: 1.2)
            }
        }
    }

    private func cancelListening() {
        activeRecordingPurpose = nil
        _ = audioRecorder.stopRecording()
        state = .idle
        overlayController.hideImmediately()
    }

    /// Returns nil (after showing an error) when nothing usable was heard.
    private func transcribe(_ recordedAudio: RecordedAudio, interactionIdentifier: UUID) async -> String? {
        prepareTranscriber()
        guard let transcriber else {
            fail(with: "Transcrierea nu e pregătită.")
            return nil
        }
        do {
            let transcript = try await transcriber.transcribe(samples: recordedAudio.samples, languageCode: settings.responseLanguage.transcriptionLanguageCode)
            guard isCurrent(interactionIdentifier) else { return nil }
            let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper sometimes "hears" these in silence.
            let silenceHallucinations: Set<String> = ["", ".", "...", "[BLANK_AUDIO]", "(silence)", "Mulțumesc.", "Thank you."]
            let looksLikeSilence = cleanedTranscript.isEmpty
                || (silenceHallucinations.contains(cleanedTranscript) && recordedAudio.durationInSeconds < 2.5)
            guard !looksLikeSilence else {
                fail(with: "Nu am auzit nimic. Ține apăsat și vorbește, apoi eliberează.")
                return nil
            }
            return cleanedTranscript
        } catch {
            guard isCurrent(interactionIdentifier) else { return nil }
            fail(with: "Transcrierea a eșuat: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Answering

    private func captureScreensForQuestion() async -> [CapturedScreen] {
        do {
            return try await screenCaptureService.captureScreens(
                includeAllScreens: settings.captureAllScreens,
                maximumLongEdge: settings.maximumScreenshotLongEdge,
                excludedBundleIdentifiers: Set(settings.excludedApplicationBundleIdentifiers)
            )
        } catch {
            // Without a screenshot Macky can still answer general questions.
            return []
        }
    }

    private func answer(question: String, capturedScreens: [CapturedScreen], frontmostApplication: FrontmostApplicationSnapshot, interactionIdentifier: UUID) async {
        guard let apiKey = apiKeyStore.apiKey(), !apiKey.isEmpty else {
            fail(with: "Adaugă cheia OpenRouter în Setări.")
            return
        }
        let modelIdentifier = settings.activeModelIdentifier
        guard !modelIdentifier.isEmpty else {
            fail(with: "Alege un model în Setări.")
            return
        }

        lastQuestionText = question
        lastAnswerText = ""
        lastAnswerModelIdentifier = modelIdentifier
        state = .thinking
        overlayController.setActivity(.thinking)
        overlayController.setBubbleText(nil)

        let coordinateConvention = settings.coordinateConvention(forModelIdentifier: modelIdentifier)
        var useToolCalling = settings.shouldUseToolCalling(forModelIdentifier: modelIdentifier, catalogModel: modelCatalogStore.model(withIdentifier: modelIdentifier))

        // Second attempt only happens when the model rejects tool calling before answering anything.
        for attemptNumber in 1...2 {
            do {
                try await streamAnswer(
                    question: question,
                    capturedScreens: capturedScreens,
                    frontmostApplication: frontmostApplication,
                    modelIdentifier: modelIdentifier,
                    apiKey: apiKey,
                    coordinateConvention: coordinateConvention,
                    useToolCalling: useToolCalling,
                    interactionIdentifier: interactionIdentifier
                )
                return
            } catch let apiError as OpenRouterAPIError where apiError.indicatesToolCallingUnsupported && useToolCalling && attemptNumber == 1 {
                settings.markModelWithoutToolCalling(modelIdentifier)
                useToolCalling = false
            } catch {
                guard isCurrent(interactionIdentifier), !(error is CancellationError) else { return }
                fail(with: Self.userFacingMessage(for: error))
                return
            }
        }
    }

    private func streamAnswer(
        question: String,
        capturedScreens: [CapturedScreen],
        frontmostApplication: FrontmostApplicationSnapshot,
        modelIdentifier: String,
        apiKey: String,
        coordinateConvention: CoordinateConvention,
        useToolCalling: Bool,
        interactionIdentifier: UUID
    ) async throws {
        let systemPrompt = MackyPrompt.systemPrompt(language: settings.responseLanguage, pointingMode: useToolCalling ? .toolCall : .textTag)
        let userText = MackyPrompt.userMessageText(
            question: question,
            screenshots: capturedScreens.map(\.promptDescription),
            frontmostApplication: frontmostApplication.context,
            coordinateConvention: coordinateConvention
        )
        let userParts: [ChatContentPart] = [.text(userText)] + capturedScreens.map { .jpegImage(base64EncodedData: $0.jpegData.base64EncodedString()) }
        conversationHistory.maximumRememberedExchanges = max(0, settings.rememberedExchangeCount)
        let messages = conversationHistory.messagesForRequest(systemPrompt: systemPrompt, currentUserParts: userParts)
        let requestBody = try OpenRouterRequestBuilder.makeChatCompletionBody(
            modelIdentifier: modelIdentifier,
            messages: messages,
            includePointingTool: useToolCalling,
            coordinateConvention: coordinateConvention
        )

        var pointTagFilter = PointTagStreamFilter()
        var sentenceSegmenter = SentenceSegmenter()
        var visibleAnswer = ""
        var pointingInstructions: [PointingInstruction] = []
        isAnswerStreamComplete = false

        func handleVisibleText(_ visibleText: String) {
            guard !visibleText.isEmpty else { return }
            visibleAnswer += visibleText
            let displayText = SpeechTextCleaner.cleanForSpeech(visibleAnswer)
            lastAnswerText = displayText
            overlayController.setBubbleText(displayText)
            if state != .speaking {
                state = .speaking
                overlayController.setActivity(.speaking)
            }
            for sentence in sentenceSegmenter.append(visibleText) {
                speak(sentence)
            }
        }

        for try await streamEvent in openRouterClient.streamChatCompletion(requestBody: requestBody, apiKey: apiKey) {
            guard isCurrent(interactionIdentifier) else { return }
            switch streamEvent {
            case .textDelta(let textDelta):
                let filteredOutput = pointTagFilter.consume(textDelta)
                pointingInstructions += filteredOutput.pointingInstructions
                handleVisibleText(filteredOutput.visibleText)
            case .toolCall(let name, let argumentsJSON):
                if name == OpenRouterRequestBuilder.pointAtToolName, let instruction = PointingInstruction(toolArgumentsJSON: argumentsJSON) {
                    pointingInstructions.append(instruction)
                }
            case .usage(let usage):
                costTracker.record(usage)
            case .finished:
                break
            }
        }
        guard isCurrent(interactionIdentifier) else { return }

        handleVisibleText(pointTagFilter.flush())
        if let lastSentence = sentenceSegmenter.flush() {
            speak(lastSentence)
        }

        var finalAnswer = SpeechTextCleaner.cleanForSpeech(visibleAnswer)
        if finalAnswer.isEmpty {
            if let firstInstruction = pointingInstructions.first {
                finalAnswer = firstInstruction.label.isEmpty ? "Uite aici." : "Uite aici: \(firstInstruction.label)."
                speak(finalAnswer)
            } else {
                finalAnswer = "Modelul nu a trimis niciun răspuns. Încearcă din nou sau alege alt model."
            }
            lastAnswerText = finalAnswer
            overlayController.setBubbleText(finalAnswer)
        }

        let pointedLabels = pointingInstructions.map(\.label).filter { !$0.isEmpty }
        let rememberedAnswer = pointedLabels.isEmpty ? finalAnswer : finalAnswer + " (Am arătat pe ecran: \(pointedLabels.joined(separator: ", ")).)"
        conversationHistory.record(userText: question, assistantText: rememberedAnswer)
        isAnswerStreamComplete = true

        if !pointingInstructions.isEmpty {
            await point(
                at: pointingInstructions,
                capturedScreens: capturedScreens,
                coordinateConvention: coordinateConvention,
                frontmostApplication: frontmostApplication,
                interactionIdentifier: interactionIdentifier
            )
        }
        guard isCurrent(interactionIdentifier) else { return }
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        }
    }

    private func speak(_ sentence: String) {
        guard settings.speakResponses else { return }
        speechSpeaker.speak(
            SpeechTextCleaner.cleanForSpeech(sentence),
            voiceIdentifier: settings.speechVoiceIdentifier,
            languageCode: settings.responseLanguage.transcriptionLanguageCode,
            rateMultiplier: settings.speechRateMultiplier
        )
    }

    private func speechQueueDrained() {
        guard isAnswerStreamComplete, state == .speaking else { return }
        finishInteraction()
    }

    private func finishInteraction() {
        state = .idle
        if overlayController.isShowingPointing {
            // The pointing watcher hides the overlay once the user clicks or the window moves.
            return
        }
        overlayController.endInteraction(afterDelay: 1.5)
    }

    // MARK: Pointing

    private func point(
        at pointingInstructions: [PointingInstruction],
        capturedScreens: [CapturedScreen],
        coordinateConvention: CoordinateConvention,
        frontmostApplication: FrontmostApplicationSnapshot,
        interactionIdentifier: UUID
    ) async {
        guard !capturedScreens.isEmpty else { return }

        // If the window moved since the screenshot, the coordinates are wrong. Better to say so than to point at the wrong thing.
        if let processIdentifier = frontmostApplication.processIdentifier,
           let windowFrameAtCapture = frontmostApplication.focusedWindowFrameInQuartzCoordinates,
           let currentWindowFrame = accessibilityInspector.focusedWindowFrame(ofProcess: processIdentifier),
           !Self.framesAreNearlyEqual(windowFrameAtCapture, currentWindowFrame) {
            overlayController.setBubbleText("Fereastra s-a mutat între timp. Întreabă-mă din nou și îți arăt.")
            return
        }

        let primaryScreenHeight = NSScreen.primaryScreenHeight
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let stepsToShow = Array(pointingInstructions.prefix(Self.maximumPointingSteps))

        for (stepIndex, instruction) in stepsToShow.enumerated() {
            guard isCurrent(interactionIdentifier) else { return }
            guard let screen = capturedScreens.first(where: { $0.geometry.screenNumber == instruction.screenNumber }) ?? capturedScreens.first else { continue }

            let imagePixel = coordinateConvention.imagePixelPoint(modelX: instruction.x, modelY: instruction.y, imagePixelSize: screen.geometry.imagePixelSize)
            var targetPoint = ScreenGeometry.appKitGlobalPoint(fromImagePixel: imagePixel, on: screen.geometry)
            var highlightRect: CGRect?

            // Snap to the real control under the point when Accessibility knows about it.
            let quartzPoint = ScreenGeometry.quartzGlobalPoint(fromAppKitGlobalPoint: targetPoint, primaryScreenHeight: primaryScreenHeight)
            if let element = accessibilityInspector.interactiveElement(atQuartzGlobalPoint: quartzPoint),
               element.processIdentifier != ownProcessIdentifier {
                let elementRect = ScreenGeometry.appKitGlobalRect(fromQuartzGlobalRect: element.frameInQuartzGlobalCoordinates, primaryScreenHeight: primaryScreenHeight)
                let elementCenter = CGPoint(x: elementRect.midX, y: elementRect.midY)
                if AccessibilitySnapPolicy.shouldSnap(
                    role: element.role,
                    elementFrame: elementRect,
                    screenFrame: screen.geometry.frameInAppKitGlobalCoordinates,
                    distanceFromTargetPoint: ScreenGeometry.distance(from: targetPoint, to: elementCenter)
                ) {
                    highlightRect = elementRect
                    targetPoint = elementCenter
                }
            }

            let label = stepsToShow.count > 1 ? "\(stepIndex + 1). \(instruction.label)" : instruction.label
            await overlayController.flyCursor(to: targetPoint, highlightRect: highlightRect, label: label)
            if stepIndex < stepsToShow.count - 1 {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
            }
        }

        guard isCurrent(interactionIdentifier) else { return }
        startWatchingPointing(frontmostApplication: frontmostApplication, interactionIdentifier: interactionIdentifier)
    }

    /// Hides the pointer when the user clicks anywhere, the window moves, or after a while.
    private func startWatchingPointing(frontmostApplication: FrontmostApplicationSnapshot, interactionIdentifier: UUID) {
        stopWatchingPointing()
        let watchStartDate = Date()
        let maximumPointingDuration: TimeInterval = 12

        pointingClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrent(interactionIdentifier) else { return }
                // Let the click land visibly before the pointer disappears.
                try? await Task.sleep(nanoseconds: 350_000_000)
                self.endPointing(interactionIdentifier: interactionIdentifier)
            }
        }

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCurrent(interactionIdentifier) else { return }
                var windowMoved = false
                if let processIdentifier = frontmostApplication.processIdentifier,
                   let windowFrameAtCapture = frontmostApplication.focusedWindowFrameInQuartzCoordinates,
                   let currentWindowFrame = self.accessibilityInspector.focusedWindowFrame(ofProcess: processIdentifier) {
                    windowMoved = !CompanionSession.framesAreNearlyEqual(windowFrameAtCapture, currentWindowFrame)
                }
                if windowMoved || Date().timeIntervalSince(watchStartDate) > maximumPointingDuration {
                    self.endPointing(interactionIdentifier: interactionIdentifier)
                }
            }
        }
        pointingWatchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endPointing(interactionIdentifier: UUID) {
        guard isCurrent(interactionIdentifier) else { return }
        stopWatchingPointing()
        overlayController.clearPointing()
        if !state.isBusy {
            overlayController.endInteraction(afterDelay: 0.3)
        }
    }

    private func stopWatchingPointing() {
        pointingWatchTimer?.invalidate()
        pointingWatchTimer = nil
        if let pointingClickMonitor {
            NSEvent.removeMonitor(pointingClickMonitor)
        }
        pointingClickMonitor = nil
    }

    // MARK: Helpers

    private func startNewInteraction() -> UUID {
        let interactionIdentifier = UUID()
        currentInteractionIdentifier = interactionIdentifier
        return interactionIdentifier
    }

    private func isCurrent(_ interactionIdentifier: UUID) -> Bool {
        interactionIdentifier == currentInteractionIdentifier
    }

    private func fail(with message: String) {
        state = .failed(message: message)
        lastAnswerText = message
        overlayController.beginInteractionIfHidden(activity: .error)
        overlayController.setActivity(.error)
        overlayController.setBubbleText(message)
        overlayController.endInteraction(afterDelay: 4)
    }

    private func ensureMicrophoneAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            _ = startNewInteraction()
            fail(with: "Permite accesul la microfon, apoi încearcă din nou.")
            return false
        default:
            _ = startNewInteraction()
            fail(with: "Macky nu are acces la microfon. Deschide meniul Macky → Permisiuni.")
            return false
        }
    }

    private static func framesAreNearlyEqual(_ firstFrame: CGRect, _ secondFrame: CGRect) -> Bool {
        abs(firstFrame.minX - secondFrame.minX) < 4 && abs(firstFrame.minY - secondFrame.minY) < 4
            && abs(firstFrame.width - secondFrame.width) < 4 && abs(firstFrame.height - secondFrame.height) < 4
    }

    static func userFacingMessage(for error: Error) -> String {
        if let apiError = error as? OpenRouterAPIError {
            if apiError.indicatesInvalidAPIKey { return "Cheia OpenRouter nu e validă. Verific-o în Setări." }
            if apiError.indicatesInsufficientCredits { return "Nu mai ai credite OpenRouter pentru acest model." }
            return apiError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Nu am conexiune la internet."
            case .timedOut: return "Modelul a răspuns prea greu. Încearcă din nou."
            default: return "Eroare de rețea: \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
