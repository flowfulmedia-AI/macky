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
    /// "Transcriere 0,8s · primul răspuns 1,5s · total 3,1s", to see where time goes.
    @Published private(set) var lastTimingSummary: String?

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
    private let drawingOverlayController: DrawingOverlayController
    private let actionConfirmationController = ActionConfirmationController()
    private let screenActionExecutor: ScreenActionExecutor
    private let accessibilityElementFinder = AccessibilityElementFinder()
    private let spotifyController: SpotifyController

    private var transcriber: SpeechTranscriber?
    private var transcriberConfigurationKey = ""
    private var conversationHistory = ConversationHistory()

    /// Every interaction gets a new identifier; async work checks it so an interrupted
    /// interaction can never update the UI or speak after a newer one started.
    private var currentInteractionIdentifier = UUID()
    private var currentInteractionTask: Task<Void, Never>?
    private var activeRecordingPurpose: HotkeyAction?
    private var isAnswerStreamComplete = false
    /// Set when the user answers "Da pentru tot": no more confirmation cards until the next question.
    private var areActionsApprovedForCurrentQuestion = false
    private var interactionTimings: InteractionTimings?

    private var pointingWatchTimer: Timer?
    private var pointingClickMonitor: Any?

    private static let minimumRecordingDurationInSeconds = 0.3
    private static let maximumPointingSteps = 5
    /// Upper bound on model round trips for one question when Macky acts on the computer.
    private static let maximumAgentSteps = 8

    init(settings: AppSettings, apiKeyStore: OpenRouterAPIKeyStore, modelCatalogStore: ModelCatalogStore,
         overlayController: CompanionOverlayController, drawingOverlayController: DrawingOverlayController,
         spotifyCredentialsStore: SpotifyCredentialsStore,
         openRouterClient: OpenRouterClient) {
        self.settings = settings
        self.apiKeyStore = apiKeyStore
        self.modelCatalogStore = modelCatalogStore
        self.overlayController = overlayController
        self.drawingOverlayController = drawingOverlayController
        self.openRouterClient = openRouterClient
        self.screenActionExecutor = ScreenActionExecutor(textInserter: dictationTextInserter)
        self.spotifyController = SpotifyController(
            executor: screenActionExecutor,
            elementFinder: accessibilityElementFinder,
            credentialsStore: spotifyCredentialsStore
        )
        spotifyController.warmUp()

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
        actionConfirmationController.cancelPendingConfirmation()
        drawingOverlayController.clear()
        overlayController.hideImmediately()
        interactionTimings = nil
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
        if purpose == .talk {
            // Connect to OpenRouter now, while the user speaks, instead of after they finish.
            openRouterClient.warmUpConnection()
            if settings.drawingEnabled {
                // While the keys are held, moving the mouse leaves a trail.
                drawingOverlayController.beginDrawingSession()
            }
        }
    }

    private func finishListening() {
        guard let purpose = activeRecordingPurpose else { return }
        activeRecordingPurpose = nil
        let recordedAudio = audioRecorder.stopRecording()
        let interactionIdentifier = currentInteractionIdentifier
        drawingOverlayController.endDrawingSession()
        let userDrawingStrokes = drawingOverlayController.meaningfulStrokes

        guard recordedAudio.durationInSeconds >= Self.minimumRecordingDurationInSeconds else {
            state = .idle
            drawingOverlayController.clear()
            overlayController.hideImmediately()
            return
        }

        state = .transcribing
        overlayController.setActivity(.thinking)
        interactionTimings = InteractionTimings(releaseDate: Date())

        currentInteractionTask = Task {
            switch purpose {
            case .talk:
                // The screen is captured right at release, while the user still looks at what they asked about.
                let frontmostApplication = accessibilityInspector.frontmostApplicationSnapshot()
                async let capturedScreensTask = captureScreensForQuestion(userDrawingStrokes: userDrawingStrokes)
                let transcript = await transcribe(recordedAudio, interactionIdentifier: interactionIdentifier)
                interactionTimings?.transcriptionFinishedDate = Date()
                guard isCurrent(interactionIdentifier), let transcript else { return }

                // Music requests go straight to Spotify: no screenshot, no model, verified playback.
                if settings.quickCommandsEnabled && settings.actionMode != .disabled,
                   let spotifyCommand = SpotifyCommandMatcher.match(transcript) {
                    await runSpotifyCommand(spotifyCommand, question: transcript, interactionIdentifier: interactionIdentifier)
                    return
                }

                // Simple commands ("pauză", "deschide Safari") run instantly, without screenshot or model.
                if settings.quickCommandsEnabled && settings.actionMode != .disabled,
                   let quickCommand = QuickCommandMatcher.match(transcript),
                   await runQuickCommand(quickCommand, question: transcript, interactionIdentifier: interactionIdentifier) {
                    return
                }

                let capturedScreens = await capturedScreensTask
                guard isCurrent(interactionIdentifier) else { return }
                await answer(question: transcript, capturedScreens: capturedScreens, frontmostApplication: frontmostApplication,
                             userDrawingStrokes: userDrawingStrokes, interactionIdentifier: interactionIdentifier)
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

    /// Says a short "Sigur, pornesc acum!" right away, then drives Spotify and only speaks again if it failed.
    private func runSpotifyCommand(_ spotifyCommand: SpotifyCommand, question: String, interactionIdentifier: UUID) async {
        lastQuestionText = question
        lastAnswerText = ""
        isAnswerStreamComplete = false
        switch spotifyCommand {
        case .play, .playLikedSongs, .resume: showAndSpeak("Sigur, pornesc acum!")
        case .pause, .nextTrack, .previousTrack: showAndSpeak("Sigur!")
        }
        interactionTimings?.firstResponseDate = Date()

        let outcome = await spotifyController.perform(spotifyCommand)
        guard isCurrent(interactionIdentifier) else { return }
        interactionTimings?.workFinishedDate = Date()
        if outcome.succeeded {
            // What is playing is shown, not read out.
            lastAnswerText += " " + outcome.message
            overlayController.setBubbleText(lastAnswerText)
        } else {
            showAndSpeak(outcome.message)
        }
        conversationHistory.record(userText: question, assistantText: lastAnswerText)
        isAnswerStreamComplete = true
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        }
    }

    /// Returns false when the command cannot be handled locally (e.g. no app with that name),
    /// so the model gets the request instead.
    private func runQuickCommand(_ quickCommand: QuickCommand, question: String, interactionIdentifier: UUID) async -> Bool {
        if case .openApplication(let name) = quickCommand.action, ScreenActionExecutor.findApplication(named: name) == nil {
            return false
        }
        lastQuestionText = question
        lastAnswerText = ""
        isAnswerStreamComplete = false
        showAndSpeak(quickCommand.acknowledgement)
        interactionTimings?.firstResponseDate = Date()

        switch quickCommand.action {
        case .mediaKey(let mediaKey):
            screenActionExecutor.press(mediaKey)
        case .openApplication(let name):
            _ = await screenActionExecutor.openApplication(named: name)
        default:
            break
        }
        guard isCurrent(interactionIdentifier) else { return true }
        interactionTimings?.wasQuickCommand = true
        interactionTimings?.workFinishedDate = Date()
        conversationHistory.record(userText: question, assistantText: quickCommand.acknowledgement + " (Am făcut: \(quickCommand.action.userFacingDescription).)")
        isAnswerStreamComplete = true
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        }
        return true
    }

    private func cancelListening() {
        activeRecordingPurpose = nil
        _ = audioRecorder.stopRecording()
        drawingOverlayController.clear()
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

    private func captureScreensForQuestion(userDrawingStrokes: [[CGPoint]] = []) async -> [CapturedScreen] {
        do {
            return try await screenCaptureService.captureScreens(
                includeAllScreens: settings.captureAllScreens,
                maximumLongEdge: settings.maximumScreenshotLongEdge,
                excludedBundleIdentifiers: Set(settings.excludedApplicationBundleIdentifiers),
                userDrawingStrokes: userDrawingStrokes
            )
        } catch {
            // Without a screenshot Macky can still answer general questions.
            return []
        }
    }

    private func answer(question: String, capturedScreens: [CapturedScreen], frontmostApplication: FrontmostApplicationSnapshot,
                        userDrawingStrokes: [[CGPoint]] = [], interactionIdentifier: UUID) async {
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
        var disableReasoning = settings.shouldDisableReasoning(forModelIdentifier: modelIdentifier)

        // Retries only happen when the model rejects a setting before answering anything;
        // the model is remembered so the next question goes straight through.
        for _ in 1...3 {
            do {
                try await runConversationTurn(
                    question: question,
                    capturedScreens: capturedScreens,
                    frontmostApplication: frontmostApplication,
                    userDrawingStrokes: userDrawingStrokes,
                    modelIdentifier: modelIdentifier,
                    apiKey: apiKey,
                    coordinateConvention: coordinateConvention,
                    useToolCalling: useToolCalling,
                    disableReasoning: disableReasoning,
                    interactionIdentifier: interactionIdentifier
                )
                return
            } catch let apiError as OpenRouterAPIError where apiError.indicatesReasoningSettingRejected && disableReasoning {
                settings.markModelRejectingReasoningSetting(modelIdentifier)
                disableReasoning = false
            } catch let apiError as OpenRouterAPIError where apiError.indicatesToolCallingUnsupported && useToolCalling {
                settings.markModelWithoutToolCalling(modelIdentifier)
                useToolCalling = false
            } catch let apiError as OpenRouterAPIError where apiError.httpStatusCode == 400 && (disableReasoning || useToolCalling) {
                // A request the provider rejects without saying why: drop the optional extras one at a time
                // (first the reasoning setting, then tools) so the user still gets an answer.
                if disableReasoning {
                    disableReasoning = false
                } else {
                    useToolCalling = false
                }
            } catch {
                guard isCurrent(interactionIdentifier), !(error is CancellationError) else { return }
                fail(with: Self.userFacingMessage(for: error))
                return
            }
        }
    }

    /// One user question, which may take several model steps when Macky acts on the computer:
    /// the model answers (and may point or ask for actions) → Macky performs the actions →
    /// takes a fresh screenshot → the model checks the result and continues, until it stops acting.
    private func runConversationTurn(
        question: String,
        capturedScreens: [CapturedScreen],
        frontmostApplication: FrontmostApplicationSnapshot,
        userDrawingStrokes: [[CGPoint]],
        modelIdentifier: String,
        apiKey: String,
        coordinateConvention: CoordinateConvention,
        useToolCalling: Bool,
        disableReasoning: Bool,
        interactionIdentifier: UUID
    ) async throws {
        let actionsEnabled = useToolCalling && settings.actionMode != .disabled
        var tools: [MackyTool] = useToolCalling ? [.pointAt] : []
        if actionsEnabled { tools += MackyTool.actingTools }

        let systemPrompt = MackyPrompt.systemPrompt(
            language: settings.responseLanguage,
            pointingMode: useToolCalling ? .toolCall : .textTag,
            actionsEnabled: actionsEnabled
        )
        let userText = MackyPrompt.userMessageText(
            question: question,
            screenshots: capturedScreens.map(\.promptDescription),
            frontmostApplication: frontmostApplication.context,
            coordinateConvention: coordinateConvention,
            userMarkings: Self.markings(from: userDrawingStrokes, on: capturedScreens, coordinateConvention: coordinateConvention)
        )
        let userParts: [ChatContentPart] = [.text(userText)] + capturedScreens.map { .jpegImage(base64EncodedData: $0.jpegData.base64EncodedString()) }
        conversationHistory.maximumRememberedExchanges = max(0, settings.rememberedExchangeCount)
        var messages = conversationHistory.messagesForRequest(systemPrompt: systemPrompt, currentUserParts: userParts)

        var currentScreens = capturedScreens
        var spokenAnswerParts: [String] = []
        var pointedLabels: [String] = []
        var performedActionDescriptions: [String] = []
        isAnswerStreamComplete = false
        areActionsApprovedForCurrentQuestion = false

        agentLoop: for stepNumber in 1...Self.maximumAgentSteps {
            // Only the first response is spoken live (the answer, or the short "Sigur, mă ocup!").
            // Later steps of a task stay quiet unless they end the task with something to say.
            let isFirstStep = stepNumber == 1
            let stepResult = try await streamModelStep(
                messages: messages,
                tools: tools,
                modelIdentifier: modelIdentifier,
                apiKey: apiKey,
                coordinateConvention: coordinateConvention,
                disableReasoning: disableReasoning,
                speaksTextLive: isFirstStep,
                interactionIdentifier: interactionIdentifier
            )
            guard isCurrent(interactionIdentifier) else { return }
            if !stepResult.visibleText.isEmpty { spokenAnswerParts.append(stepResult.visibleText) }
            pointedLabels += stepResult.pointingInstructions.map(\.label).filter { !$0.isEmpty }

            let requestedActions = stepResult.toolCalls.compactMap { ScreenAction(toolCall: $0) }
            let modelSaysTaskIsDone = stepResult.toolCalls.contains { $0.name == MackyTool.taskDone.rawValue }
            guard actionsEnabled, !requestedActions.isEmpty else {
                if !isFirstStep && !stepResult.visibleText.isEmpty {
                    // A quiet step that ends with a message (a problem, a question): say it now.
                    showAndSpeak(stepResult.visibleText)
                }
                // A normal answer: show what the model pointed at and finish.
                if !stepResult.pointingInstructions.isEmpty {
                    await point(
                        at: stepResult.pointingInstructions,
                        capturedScreens: currentScreens,
                        coordinateConvention: coordinateConvention,
                        frontmostApplication: stepNumber == 1 ? frontmostApplication : accessibilityInspector.frontmostApplicationSnapshot(),
                        interactionIdentifier: interactionIdentifier
                    )
                }
                break agentLoop
            }

            // Every tool call needs a result in the next request, in the same order.
            messages.append(ChatMessage(
                role: .assistant,
                parts: stepResult.visibleText.isEmpty ? [] : [.text(stepResult.visibleText)],
                toolCalls: stepResult.toolCalls
            ))
            var userDeclined = false
            var anyActionFailed = false
            for toolCall in stepResult.toolCalls {
                let resultText: String
                if userDeclined {
                    resultText = "Skipped because the user declined an earlier action."
                } else if anyActionFailed && ScreenAction(toolCall: toolCall) != nil {
                    resultText = "Skipped because an earlier action failed."
                } else if let action = ScreenAction(toolCall: toolCall) {
                    switch await perform(action, on: currentScreens, coordinateConvention: coordinateConvention, stepNumber: stepNumber, interactionIdentifier: interactionIdentifier) {
                    case .done(let description, let resultDetail):
                        performedActionDescriptions.append(description)
                        resultText = resultDetail.map { $0.isEmpty ? "Done." : "Done. Result: \($0)" } ?? "Done."
                    case .declined:
                        userDeclined = true
                        resultText = "The user declined this action."
                    case .failed(let reason):
                        anyActionFailed = true
                        resultText = "Failed: \(reason)"
                    }
                } else if toolCall.name == MackyTool.pointAt.rawValue {
                    resultText = "Shown to the user."
                } else if toolCall.name == MackyTool.taskDone.rawValue {
                    resultText = "OK."
                } else {
                    resultText = "Invalid tool call arguments."
                }
                guard isCurrent(interactionIdentifier) else { return }
                messages.append(.toolResult(for: toolCall, result: resultText))
            }

            // The model said these actions finish the task: no extra screenshot and round trip.
            if modelSaysTaskIsDone && !userDeclined && !anyActionFailed {
                break agentLoop
            }

            if userDeclined {
                let declinedAnswer = "Bine, nu fac asta."
                spokenAnswerParts.append(declinedAnswer)
                showAndSpeak(declinedAnswer)
                break agentLoop
            }
            if stepNumber == Self.maximumAgentSteps {
                let limitAnswer = "Am făcut \(performedActionDescriptions.count) pași și mă opresc aici. Spune-mi dacă să continui."
                spokenAnswerParts.append(limitAnswer)
                showAndSpeak(limitAnswer)
                break agentLoop
            }

            // Let the app react, then look again so the model can verify the step.
            state = .thinking
            overlayController.setActivity(.thinking)
            // Launching an app or loading a page takes longer than a click to show up on screen.
            let openedSomething = requestedActions.contains { action in
                switch action {
                case .openApplication, .openURL: return true
                default: return false
                }
            }
            try await Task.sleep(nanoseconds: openedSomething ? 1_100_000_000 : 400_000_000)
            guard isCurrent(interactionIdentifier) else { return }
            currentScreens = await captureScreensForQuestion()
            let observationText = MackyPrompt.afterActionsMessageText(
                screenshots: currentScreens.map(\.promptDescription),
                coordinateConvention: coordinateConvention
            )
            messages.append(ChatMessage(
                role: .user,
                parts: [.text(observationText)] + currentScreens.map { .jpegImage(base64EncodedData: $0.jpegData.base64EncodedString()) }
            ))
            messages = Self.keepingOnlyNewestScreenshots(in: messages)
        }

        var finalAnswer = SpeechTextCleaner.cleanForSpeech(spokenAnswerParts.joined(separator: " "))
        if finalAnswer.isEmpty {
            if let firstLabel = pointedLabels.first {
                finalAnswer = "Uite aici: \(firstLabel)."
                speak(finalAnswer)
            } else if !performedActionDescriptions.isEmpty {
                // Shown, not spoken: the user asked for fewer words while Macky works.
                finalAnswer = "Gata."
            } else {
                finalAnswer = "Modelul nu a trimis niciun răspuns. Încearcă din nou sau alege alt model."
            }
            lastAnswerText = finalAnswer
            overlayController.setBubbleText(finalAnswer)
        }

        var rememberedAnswer = finalAnswer
        if !pointedLabels.isEmpty { rememberedAnswer += " (Am arătat pe ecran: \(pointedLabels.joined(separator: ", ")).)" }
        if !performedActionDescriptions.isEmpty { rememberedAnswer += " (Am făcut: \(performedActionDescriptions.joined(separator: "; ")).)" }
        conversationHistory.record(userText: question, assistantText: rememberedAnswer)
        interactionTimings?.workFinishedDate = Date()
        isAnswerStreamComplete = true

        guard isCurrent(interactionIdentifier) else { return }
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        }
    }

    private struct ModelStepResult {
        var visibleText: String
        var pointingInstructions: [PointingInstruction]
        var toolCalls: [ChatToolCall]
    }

    /// Streams one model response: shows and speaks text as it arrives, collects tool calls.
    private func streamModelStep(
        messages: [ChatMessage],
        tools: [MackyTool],
        modelIdentifier: String,
        apiKey: String,
        coordinateConvention: CoordinateConvention,
        disableReasoning: Bool,
        speaksTextLive: Bool,
        interactionIdentifier: UUID
    ) async throws -> ModelStepResult {
        let requestBody = try OpenRouterRequestBuilder.makeChatCompletionBody(
            modelIdentifier: modelIdentifier,
            messages: messages,
            tools: tools,
            coordinateConvention: coordinateConvention,
            disableReasoning: disableReasoning
        )

        var pointTagFilter = PointTagStreamFilter()
        var sentenceSegmenter = SentenceSegmenter()
        var stepText = ""
        var pointingInstructions: [PointingInstruction] = []
        var toolCalls: [ChatToolCall] = []
        // Text from earlier steps of the same question stays in the bubble.
        let earlierAnswerText = lastAnswerText

        func handleVisibleText(_ visibleText: String) {
            guard !visibleText.isEmpty else { return }
            stepText += visibleText
            // Quiet steps collect their text; the caller decides whether to say it at the end.
            guard speaksTextLive else { return }
            let stepDisplayText = SpeechTextCleaner.cleanForSpeech(stepText)
            let displayText = earlierAnswerText.isEmpty ? stepDisplayText : earlierAnswerText + " " + stepDisplayText
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
            guard isCurrent(interactionIdentifier) else { break }
            if interactionTimings != nil && interactionTimings?.firstResponseDate == nil {
                if case .textDelta = streamEvent { interactionTimings?.firstResponseDate = Date() }
                if case .toolCall = streamEvent { interactionTimings?.firstResponseDate = Date() }
            }
            switch streamEvent {
            case .textDelta(let textDelta):
                let filteredOutput = pointTagFilter.consume(textDelta)
                pointingInstructions += filteredOutput.pointingInstructions
                handleVisibleText(filteredOutput.visibleText)
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
                if toolCall.name == MackyTool.pointAt.rawValue, let instruction = PointingInstruction(toolArgumentsJSON: toolCall.argumentsJSON) {
                    pointingInstructions.append(instruction)
                }
            case .usage(let usage):
                costTracker.record(usage)
            case .finished:
                break
            }
        }

        if isCurrent(interactionIdentifier) {
            handleVisibleText(pointTagFilter.flush())
            if speaksTextLive, let lastSentence = sentenceSegmenter.flush() {
                speak(lastSentence)
            }
        }
        return ModelStepResult(visibleText: SpeechTextCleaner.cleanForSpeech(stepText), pointingInstructions: pointingInstructions, toolCalls: toolCalls)
    }

    private func showAndSpeak(_ text: String) {
        lastAnswerText = lastAnswerText.isEmpty ? text : lastAnswerText + " " + text
        overlayController.setBubbleText(lastAnswerText)
        state = .speaking
        overlayController.setActivity(.speaking)
        speak(text)
    }

    // MARK: Acting

    private enum ActionOutcome {
        /// `resultDetail` is sent back to the model, e.g. what an AppleScript returned.
        case done(String, resultDetail: String?)
        case declined
        case failed(String)
    }

    private func perform(_ action: ScreenAction, on screens: [CapturedScreen], coordinateConvention: CoordinateConvention,
                         stepNumber: Int, interactionIdentifier: UUID) async -> ActionOutcome {
        guard accessibilityInspector.isTrusted else {
            return .failed("Macky does not have the Accessibility permission, so it cannot click or type.")
        }

        var clickTarget: CGPoint?
        if case .click(let target, _) = action {
            guard let resolvedTarget = resolveTarget(of: target, on: screens, coordinateConvention: coordinateConvention) else {
                return .failed("That position is not on any captured screen.")
            }
            clickTarget = resolvedTarget.point
            // Show where the click will land before it happens.
            // Quick flight: when acting, speed matters more than the animation.
            await overlayController.flyCursor(to: resolvedTarget.point, highlightRect: resolvedTarget.highlightRect,
                                              label: target.label, maximumFlightDuration: 0.3)
            guard isCurrent(interactionIdentifier) else { return .declined }
        }

        if settings.actionMode == .askFirst && !areActionsApprovedForCurrentQuestion {
            let answer = await actionConfirmationController.requestConfirmation(
                actionDescription: action.userFacingDescription,
                stepNumber: stepNumber,
                nearPoint: clickTarget
            )
            guard isCurrent(interactionIdentifier) else { return .declined }
            switch answer {
            case .declined:
                overlayController.clearPointing()
                return .declined
            case .approvedForRestOfTask:
                areActionsApprovedForCurrentQuestion = true
            case .approved:
                break
            }
        }

        overlayController.clearPointing()
        switch action {
        case .click(_, let kind):
            if let clickTarget {
                await screenActionExecutor.click(atAppKitGlobalPoint: clickTarget, kind: kind)
            }
        case .typeText(let text, let pressEnterAfterwards):
            await screenActionExecutor.type(text, pressEnterAfterwards: pressEnterAfterwards)
        case .pressKeys(let combination):
            screenActionExecutor.press(combination)
        case .openApplication(let name):
            guard await screenActionExecutor.openApplication(named: name) else {
                return .failed("No installed application is called \(name).")
            }
        case .openURL(let url):
            guard screenActionExecutor.openURL(url) else {
                return .failed("This URL could not be opened.")
            }
        case .runAppleScript(let script):
            let scriptResult = await screenActionExecutor.runAppleScript(script)
            guard scriptResult.succeeded else {
                return .failed("AppleScript error: \(scriptResult.output)")
            }
            return .done(action.userFacingDescription, resultDetail: scriptResult.output)
        case .mediaKey(let mediaKey):
            screenActionExecutor.press(mediaKey)
        case .spotify(let spotifyCommand):
            let outcome = await spotifyController.perform(spotifyCommand)
            guard outcome.succeeded else { return .failed(outcome.message) }
            return .done(action.userFacingDescription, resultDetail: outcome.message)
        case .clickElement(let label, let applicationName):
            let pressResult = await accessibilityElementFinder.pressElement(label: label, applicationName: applicationName)
            guard pressResult.succeeded else {
                return .failed(pressResult.message)
            }
            return .done(action.userFacingDescription, resultDetail: pressResult.message)
        }
        // A short pause lets the app handle one input before the next one arrives.
        try? await Task.sleep(nanoseconds: 150_000_000)
        return .done(action.userFacingDescription, resultDetail: nil)
    }

    /// Converts a model coordinate to a real screen point, snapping to the control underneath
    /// when Accessibility can see one.
    private func resolveTarget(of instruction: PointingInstruction, on screens: [CapturedScreen],
                               coordinateConvention: CoordinateConvention) -> (point: CGPoint, highlightRect: CGRect?)? {
        guard let screen = screens.first(where: { $0.geometry.screenNumber == instruction.screenNumber }) ?? screens.first else { return nil }
        let primaryScreenHeight = NSScreen.primaryScreenHeight
        let imagePixel = coordinateConvention.imagePixelPoint(modelX: instruction.x, modelY: instruction.y, imagePixelSize: screen.geometry.imagePixelSize)
        let targetPoint = ScreenGeometry.appKitGlobalPoint(fromImagePixel: imagePixel, on: screen.geometry)

        let quartzPoint = ScreenGeometry.quartzGlobalPoint(fromAppKitGlobalPoint: targetPoint, primaryScreenHeight: primaryScreenHeight)
        if let element = accessibilityInspector.interactiveElement(atQuartzGlobalPoint: quartzPoint),
           element.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let elementRect = ScreenGeometry.appKitGlobalRect(fromQuartzGlobalRect: element.frameInQuartzGlobalCoordinates, primaryScreenHeight: primaryScreenHeight)
            let elementCenter = CGPoint(x: elementRect.midX, y: elementRect.midY)
            if AccessibilitySnapPolicy.shouldSnap(
                role: element.role,
                elementFrame: elementRect,
                screenFrame: screen.geometry.frameInAppKitGlobalCoordinates,
                distanceFromTargetPoint: ScreenGeometry.distance(from: targetPoint, to: elementCenter)
            ) {
                return (elementCenter, elementRect)
            }
        }
        return (targetPoint, nil)
    }

    /// Summarizes the user's drawing per screenshot, in the model's coordinates.
    private static func markings(from strokes: [[CGPoint]], on screens: [CapturedScreen], coordinateConvention: CoordinateConvention) -> [UserScreenMarking] {
        screens.compactMap { screen in
            let pointsOnScreen = strokes.joined().filter { screen.geometry.frameInAppKitGlobalCoordinates.contains($0) }
            guard !pointsOnScreen.isEmpty else { return nil }
            let bounds = DrawingOverlayController.boundingBox(of: Array(pointsOnScreen))
            let topLeftPixel = ScreenGeometry.imagePixel(fromAppKitGlobalPoint: CGPoint(x: bounds.minX, y: bounds.maxY), on: screen.geometry)
            let bottomRightPixel = ScreenGeometry.imagePixel(fromAppKitGlobalPoint: CGPoint(x: bounds.maxX, y: bounds.minY), on: screen.geometry)
            let topLeft = coordinateConvention.modelPoint(fromImagePixel: topLeftPixel, imagePixelSize: screen.geometry.imagePixelSize)
            let bottomRight = coordinateConvention.modelPoint(fromImagePixel: bottomRightPixel, imagePixelSize: screen.geometry.imagePixelSize)
            return UserScreenMarking(
                screenNumber: screen.geometry.screenNumber,
                minimumX: Double(topLeft.x), minimumY: Double(topLeft.y),
                maximumX: Double(bottomRight.x), maximumY: Double(bottomRight.y)
            )
        }
    }

    /// Screenshots are the expensive part of a request; after a few action steps only the newest one matters.
    private static func keepingOnlyNewestScreenshots(in messages: [ChatMessage]) -> [ChatMessage] {
        guard let newestIndexWithImage = messages.lastIndex(where: \.containsImage) else { return messages }
        return messages.enumerated().map { index, message in
            guard index != newestIndexWithImage, message.containsImage else { return message }
            var trimmedMessage = message
            trimmedMessage.parts = message.parts.map { part in
                if case .jpegImage = part { return .text("[older screenshot removed]") }
                return part
            }
            return trimmedMessage
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
        drawingOverlayController.clear()
        if let interactionTimings {
            lastTimingSummary = interactionTimings.summary(finishedDate: Date())
            self.interactionTimings = nil
        }
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

        let stepsToShow = Array(pointingInstructions.prefix(Self.maximumPointingSteps))

        for (stepIndex, instruction) in stepsToShow.enumerated() {
            guard isCurrent(interactionIdentifier) else { return }
            guard let resolvedTarget = resolveTarget(of: instruction, on: capturedScreens, coordinateConvention: coordinateConvention) else { continue }

            let label = stepsToShow.count > 1 ? "\(stepIndex + 1). \(instruction.label)" : instruction.label
            await overlayController.flyCursor(to: resolvedTarget.point, highlightRect: resolvedTarget.highlightRect, label: label)
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
        drawingOverlayController.clear()
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

/// Where the time of one spoken request went, measured from releasing the hotkey.
struct InteractionTimings {
    let releaseDate: Date
    var transcriptionFinishedDate: Date?
    /// First text or tool call from the model (or the instant reply of a quick command).
    var firstResponseDate: Date?
    var wasQuickCommand = false
    /// When the task itself was done (speech may continue a little longer).
    var workFinishedDate: Date?

    func summary(finishedDate: Date) -> String {
        let finishedDate = workFinishedDate ?? finishedDate
        func seconds(_ date: Date?) -> String? {
            date.map { String(format: "%.1fs", $0.timeIntervalSince(releaseDate)).replacingOccurrences(of: ".", with: ",") }
        }
        var parts: [String] = []
        if wasQuickCommand { parts.append("comandă rapidă") }
        if let transcription = seconds(transcriptionFinishedDate) { parts.append("transcriere \(transcription)") }
        if let firstResponse = seconds(firstResponseDate) { parts.append("primul răspuns \(firstResponse)") }
        if let total = seconds(finishedDate) { parts.append("total \(total)") }
        return "Ultima cerere: " + parts.joined(separator: " · ")
    }
}
