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
    private let systemController: SystemController
    private let notesController: NotesController
    private let windowArranger: WindowArranger
    private let personalDataController = PersonalDataController()
    /// Long tasks that run in the background; shown in the panel.
    let backgroundAgentManager: BackgroundAgentManager
    let memoryManager: MemoryManager
    let historyStore: HistoryStore
    let skillLibrary: SkillLibrary
    let googleAccountManager: GoogleAccountManager
    let routineStore: RoutineStore
    let mcpConnectionStore: MCPConnectionStore
    let zoomMeetingsManager: ZoomMeetingsManager
    let whatsAppController: WhatsAppController
    let chatArchiveStore = ChatArchiveStore()
    let mailAccountsStore = MailAccountsStore()
    /// Set by the app once created; lets the user start their agents by voice.
    var agentStore: AgentStore?
    /// The routine being run, if the current request is one.
    private var runningRoutine: Routine?
    private let localFileSearch = LocalFileSearch()
    /// Set while Macky listens for a reply after answering, without the keys (see `startFollowUpListening`).
    private var followUpListeningIdentifier: UUID?
    private var followUpWindow: Double = FollowUpListeningPolicy.defaultWindow
    /// Whether the request being answered was spoken (follow-up listening only continues spoken conversations).
    private var currentRequestWasSpoken = false
    /// Set by answers that invite a reply (not by actions like playing music, where the mic would hear the music).
    private var shouldListenForFollowUp = false
    /// The learned procedure that answered the previous request; a correction right after counts against it.
    private var lastReplayedProcedureIdentifier: UUID?
    /// Session cost when the current request started, to know what one request cost.
    private var costAtRequestStart: Double = 0

    /// Notices when the user stops talking while still holding the keys (see `audioChunkRecorded`).
    private var speechEndpointDetector = SpeechEndpointDetector()
    /// A transcription started during the pause before the keys were released.
    private var earlyTranscription: (sampleCount: Int, task: Task<String?, Never>)?

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
    private var listeningStartDate: Date?
    private static let maximumPointingSteps = 5
    /// Upper bound on model round trips for one question when Macky acts on the computer.
    private static let maximumAgentSteps = 8

    init(settings: AppSettings, apiKeyStore: OpenRouterAPIKeyStore, modelCatalogStore: ModelCatalogStore,
         overlayController: CompanionOverlayController, drawingOverlayController: DrawingOverlayController,
         spotifyCredentialsStore: SpotifyCredentialsStore,
         openRouterClient: OpenRouterClient, memoryManager: MemoryManager, historyStore: HistoryStore, skillLibrary: SkillLibrary,
         googleAccountManager: GoogleAccountManager, routineStore: RoutineStore, mcpConnectionStore: MCPConnectionStore,
         zoomMeetingsManager: ZoomMeetingsManager) {
        self.memoryManager = memoryManager
        self.zoomMeetingsManager = zoomMeetingsManager
        self.mcpConnectionStore = mcpConnectionStore
        self.routineStore = routineStore
        self.googleAccountManager = googleAccountManager
        self.skillLibrary = skillLibrary
        self.historyStore = historyStore
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
        self.systemController = SystemController(executor: screenActionExecutor)
        self.notesController = NotesController(executor: screenActionExecutor)
        self.windowArranger = WindowArranger(executor: screenActionExecutor)
        self.whatsAppController = WhatsAppController(settings: settings, executor: screenActionExecutor)
        chatArchiveStore.onClaudeMemory = { [weak memoryManager] text in
            memoryManager?.importClaudeMemory(text)
        }
        self.backgroundAgentManager = BackgroundAgentManager(
            settings: settings,
            apiKeyStore: apiKeyStore,
            openRouterClient: openRouterClient,
            personalDataController: personalDataController,
            notesController: notesController
        )

        audioRecorder.onAudioLevel = { [weak overlayController] audioLevel in
            overlayController?.setAudioLevel(audioLevel)
        }
        audioRecorder.onAudioChunk = { [weak self] chunkLevel, sampleCount in
            self?.audioChunkRecorded(chunkLevel: chunkLevel, sampleCount: sampleCount)
        }
        backgroundAgentManager.onJobFinished = { [weak self] job in
            self?.backgroundJobFinished(job)
        }
        speechSpeaker.onAllSpeechFinished = { [weak self] in
            self?.speechQueueDrained()
        }
        prepareNeuralVoice()
        zoomMeetingsManager.transcribeAudioFile = { [weak self] fileURL in
            guard let self else { return [] }
            return try await self.transcribeMeetingAudio(at: fileURL)
        }
        zoomMeetingsManager.onMeetingSaved = { [weak self] savedNotes in
            self?.meetingSaved(savedNotes)
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
        noteNewRequest(question)
        currentRequestWasSpoken = false
        currentInteractionTask = Task {
            if settings.actionMode != .disabled, let procedure = memoryManager.procedure(matching: question),
               await runLearnedProcedure(procedure, question: question, interactionIdentifier: interactionIdentifier) {
                return
            }
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
        followUpListeningIdentifier = nil
        shouldListenForFollowUp = false
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
                            languageCode: settings.responseLanguage.transcriptionLanguageCode, rateMultiplier: settings.speechRateMultiplier,
                            neuralVoice: neuralVoiceForAnswers)
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
            audioRecorder.microphonePreference = settings.microphonePreference
            try audioRecorder.startRecording()
            listeningStartDate = Date()
        } catch {
            _ = startNewInteraction()
            fail(with: "Nu pot porni microfonul: \(error.localizedDescription)")
            return
        }
        _ = startNewInteraction()
        activeRecordingPurpose = purpose
        speechEndpointDetector = SpeechEndpointDetector()
        earlyTranscription?.task.cancel()
        earlyTranscription = nil
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
            drawingOverlayController.clear()
            // Keys held for a while but no sound arrived: the microphone is the problem, say which.
            if let listeningStartDate, Date().timeIntervalSince(listeningStartDate) > 1 {
                let microphone = recordedAudio.microphoneName.map { "„\($0)”" } ?? "Microfonul"
                fail(with: "\(microphone) nu a trimis sunet. Alege alt microfon în Setări → Voce și limbă → Microfon.")
                return
            }
            state = .idle
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
                let capturedScreensTask = Task { await self.captureScreensForQuestion(userDrawingStrokes: userDrawingStrokes) }
                let transcript = await transcribe(recordedAudio, interactionIdentifier: interactionIdentifier)
                interactionTimings?.transcriptionFinishedDate = Date()
                guard isCurrent(interactionIdentifier), let transcript else { return }
                await handleSpokenRequest(transcript, frontmostApplication: frontmostApplication, capturedScreensTask: capturedScreensTask,
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

    /// Routes a spoken request: instant local handlers first, then learned procedures, then the model.
    private func handleSpokenRequest(_ transcript: String, frontmostApplication: FrontmostApplicationSnapshot,
                                     capturedScreensTask: Task<[CapturedScreen], Never>, userDrawingStrokes: [[CGPoint]],
                                     interactionIdentifier: UUID) async {
        noteNewRequest(transcript)
        currentRequestWasSpoken = true

        // A routine the user set up ("brief de dimineață", "mod lucru").
        if let routine = RoutineMatcher.match(transcript, in: routineStore.routines) {
            routineStore.markRun(routine.id)
            await runRoutine(routine, interactionIdentifier: interactionIdentifier)
            return
        }

        // "Agent, caută…" starts a background job right away.
        if settings.actionMode != .disabled, let backgroundGoal = BackgroundTaskTrigger.goal(from: transcript) {
            startBackgroundJob(goal: backgroundGoal, question: transcript)
            return
        }

        // Volume, brightness, dark mode, lock: instant, no model.
        if settings.quickCommandsEnabled && settings.actionMode != .disabled,
           let systemCommand = SystemCommandMatcher.match(transcript) {
            await runSystemCommand(systemCommand, question: transcript, interactionIdentifier: interactionIdentifier)
            return
        }

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

        // Something Macky already learned to do by itself: replayed directly, no screenshot, no model.
        if settings.actionMode != .disabled, let procedure = memoryManager.procedure(matching: transcript),
           await runLearnedProcedure(procedure, question: transcript, interactionIdentifier: interactionIdentifier) {
            return
        }

        let capturedScreens = await capturedScreensTask.value
        guard isCurrent(interactionIdentifier) else { return }
        await answer(question: transcript, capturedScreens: capturedScreens, frontmostApplication: frontmostApplication,
                     userDrawingStrokes: userDrawingStrokes, interactionIdentifier: interactionIdentifier)
    }

    private func runSystemCommand(_ systemCommand: SystemCommand, question: String, interactionIdentifier: UUID) async {
        lastQuestionText = question
        lastAnswerText = ""
        isAnswerStreamComplete = false
        interactionTimings?.firstResponseDate = Date()
        let outcome = await systemController.perform(systemCommand)
        guard isCurrent(interactionIdentifier) else { return }
        interactionTimings?.workFinishedDate = Date()
        if outcome.succeeded {
            // Settings changes are visible (or audible) on their own: a short word is enough.
            showAndSpeak(systemCommand == .lockScreen || systemCommand == .sleepDisplay ? outcome.message : "Sigur!")
            lastAnswerText = outcome.message
            overlayController.setBubbleText(outcome.message)
        } else {
            showAndSpeak(outcome.message)
        }
        conversationHistory.record(userText: question, assistantText: outcome.message)
        recordInHistory(question: question, answer: outcome.message, actions: [systemCommand.userFacingDescription], route: .quickCommand)
        isAnswerStreamComplete = true
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        }
    }

    private func startBackgroundJob(goal: String, question: String) {
        backgroundAgentManager.start(goal: goal)
        lastQuestionText = question
        lastAnswerText = ""
        isAnswerStreamComplete = false
        showAndSpeak("Sigur, mă ocup în fundal!")
        interactionTimings?.firstResponseDate = Date()
        interactionTimings?.workFinishedDate = Date()
        conversationHistory.record(userText: question, assistantText: "Am pornit un agent în fundal pentru: \(goal)")
        recordInHistory(question: question, answer: "Agent pornit în fundal.", actions: [goal], route: .backgroundAgent)
        isAnswerStreamComplete = true
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        }
    }

    /// Announces a finished background job, unless the user is in the middle of something with Macky.
    private func backgroundJobFinished(_ job: BackgroundAgentManager.Job) {
        let announcement: String
        switch job.status {
        case .finished(let summary, _):
            announcement = "Agentul a terminat. " + summary
        case .failed(let reason):
            announcement = "Agentul nu a reușit: " + reason
        case .running, .cancelled:
            return
        }
        guard !state.isBusy else { return }
        overlayController.beginInteraction(activity: .speaking)
        lastAnswerText = announcement
        overlayController.setBubbleText(announcement)
        state = .speaking
        isAnswerStreamComplete = true
        speak(announcement)
        if !settings.speakResponses { finishInteraction() }
    }

    // MARK: Early transcription

    /// Called for every ~0.1 s of recorded audio. When the user pauses after speaking, the audio so far
    /// is transcribed right away; if they then release the keys without saying more, that transcript is used
    /// and there is nothing left to wait for.
    private func audioChunkRecorded(chunkLevel: Float, sampleCount: Int) {
        if followUpListeningIdentifier != nil {
            followUpAudioChunkRecorded(chunkLevel: chunkLevel, sampleCount: sampleCount)
            return
        }
        guard activeRecordingPurpose != nil else { return }
        speechEndpointDetector.append(chunkLevel: chunkLevel, sampleCount: sampleCount)
        guard speechEndpointDetector.hasSpeechEnded(minimumPause: 0.3, sampleRate: AudioRecorder.transcriptionSampleRate) else { return }
        // Already transcribed everything up to this pause.
        if let earlyTranscription, speechEndpointDetector.isSilentAfter(sampleIndex: earlyTranscription.sampleCount) { return }

        prepareTranscriber()
        guard let transcriber else { return }
        let samples = audioRecorder.snapshotSamples()
        guard samples.count >= Int(AudioRecorder.transcriptionSampleRate * Self.minimumRecordingDurationInSeconds) else { return }
        let languageCode = settings.responseLanguage.transcriptionLanguageCode
        earlyTranscription?.task.cancel()
        earlyTranscription = (samples.count, Task {
            try? await transcriber.transcribe(samples: samples, languageCode: languageCode)
        })
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
        recordInHistory(question: question, answer: lastAnswerText, actions: [spotifyCommand.userFacingDescription], route: .quickCommand)
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
        recordInHistory(question: question, answer: quickCommand.acknowledgement, actions: [quickCommand.action.userFacingDescription], route: .quickCommand)
        isAnswerStreamComplete = true
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        }
        return true
    }

    // MARK: Follow-up listening

    /// After an answer, listens a few seconds more: if the user replies, that reply is handled like a new
    /// spoken request (with the conversation so far); if nobody speaks, Macky stops listening quietly.
    @discardableResult
    private func startFollowUpListening(afterAnswer answer: String) -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, !audioRecorder.isRecording else { return false }
        do {
            audioRecorder.microphonePreference = settings.microphonePreference
            try audioRecorder.startRecording()
            listeningStartDate = Date()
        } catch {
            return false
        }
        let listeningIdentifier = UUID()
        followUpListeningIdentifier = listeningIdentifier
        followUpWindow = FollowUpListeningPolicy.listeningWindow(afterAnswer: answer)
        speechEndpointDetector = SpeechEndpointDetector()
        earlyTranscription?.task.cancel()
        earlyTranscription = nil
        state = .listening
        overlayController.beginInteractionIfHidden(activity: .listening)
        overlayController.setActivity(.listening)
        // Safety net in case audio stops arriving.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((FollowUpListeningPolicy.maximumDuration + 2) * 1_000_000_000))
            guard let self, self.followUpListeningIdentifier == listeningIdentifier else { return }
            self.stopFollowUpListening()
        }
        return true
    }

    private func followUpAudioChunkRecorded(chunkLevel: Float, sampleCount: Int) {
        speechEndpointDetector.append(chunkLevel: chunkLevel, sampleCount: sampleCount)
        let sampleRate = AudioRecorder.transcriptionSampleRate
        let elapsedSeconds = Double(speechEndpointDetector.totalSampleCount) / sampleRate
        switch FollowUpListeningPolicy.decide(detector: speechEndpointDetector, elapsedSeconds: elapsedSeconds, window: followUpWindow, sampleRate: sampleRate) {
        case .keepListening:
            return
        case .giveUp:
            stopFollowUpListening()
        case .finish:
            finishFollowUpListening()
        }
    }

    private func stopFollowUpListening() {
        followUpListeningIdentifier = nil
        if audioRecorder.isRecording { _ = audioRecorder.stopRecording() }
        guard state == .listening else { return }
        state = .idle
        if overlayController.isShowingPointing {
            overlayController.setActivity(.pointing)
        } else {
            overlayController.endInteraction(afterDelay: 0.2)
        }
    }

    private func finishFollowUpListening() {
        followUpListeningIdentifier = nil
        let recordedAudio = audioRecorder.stopRecording()
        stopWatchingPointing()
        overlayController.clearPointing()
        let interactionIdentifier = startNewInteraction()
        state = .transcribing
        overlayController.setActivity(.thinking)
        interactionTimings = InteractionTimings(releaseDate: Date())

        currentInteractionTask = Task {
            let frontmostApplication = accessibilityInspector.frontmostApplicationSnapshot()
            let capturedScreensTask = Task { await self.captureScreensForQuestion() }
            let transcript = await transcribe(recordedAudio, interactionIdentifier: interactionIdentifier, reportsSilence: false)
            interactionTimings?.transcriptionFinishedDate = Date()
            guard isCurrent(interactionIdentifier) else { return }
            // Noise, or "mulțumesc" / "gata": the conversation ends here.
            guard let transcript, !FollowUpListeningPolicy.isDismissal(transcript) else {
                capturedScreensTask.cancel()
                interactionTimings = nil
                state = .idle
                overlayController.endInteraction(afterDelay: 0.3)
                return
            }
            await handleSpokenRequest(transcript, frontmostApplication: frontmostApplication, capturedScreensTask: capturedScreensTask,
                                      userDrawingStrokes: [], interactionIdentifier: interactionIdentifier)
        }
    }

    // MARK: Memory, procedures, history

    /// Called once per request, before it is handled.
    private func noteNewRequest(_ question: String) {
        // "Nu asta…" right after a replayed procedure means the procedure did the wrong thing.
        if let lastReplayedProcedureIdentifier, MemoryCurator.isCorrection(question) {
            memoryManager.recordProcedureFailure(lastReplayedProcedureIdentifier)
        }
        lastReplayedProcedureIdentifier = nil
        runningRoutine = nil
        costAtRequestStart = costTracker.totalCostInCredits
    }

    // MARK: Zoom meetings

    private func transcribeMeetingAudio(at fileURL: URL) async throws -> [TranscriptLine] {
        let whisperTranscriber = (transcriber as? WhisperKitTranscriber) ?? WhisperKitTranscriber(modelVariant: settings.whisperModelVariant.rawValue)
        return try await whisperTranscriber.transcribeFile(at: fileURL, languageCode: settings.responseLanguage.transcriptionLanguageCode)
    }

    private func meetingSaved(_ savedNotes: SavedMeetingNotes) {
        let notes = savedNotes.notes
        var details = notes.summary
        if !notes.decisions.isEmpty { details += "\nDecizii: " + notes.decisions.joined(separator: "; ") }
        let actions = notes.actionItems.map { item in (item.owner.map { "\($0): " } ?? "") + item.task + (item.due.map { " (\($0))" } ?? "") }
        if !actions.isEmpty { details += "\nAcțiuni: " + actions.joined(separator: "; ") }
        historyStore.record(HistoryEntry(question: "Meeting Zoom: \(savedNotes.topic)", answer: notes.title + " · " + savedNotes.documentLink,
                                         actions: actions, route: .meeting))
        // What was said about clients and projects goes into memory too.
        memoryManager.recordExchange(question: "Notițele meetingului Zoom „\(savedNotes.topic)”", answer: details, actions: [], failures: [])
        if !state.isBusy {
            overlayController.beginInteractionIfHidden(activity: .speaking)
            overlayController.setBubbleText("📄 Meetingul „\(notes.title)” e salvat în Drive.")
            overlayController.endInteraction(afterDelay: 5)
        }
        if zoomMeetingsManager.createsTasks && !notes.actionItems.isEmpty {
            let routine = Routine(
                name: "Taskuri din meetingul „\(notes.title)”",
                triggerPhrases: [],
                schedule: RoutineSchedule(isEnabled: false, hour: 9, minute: 0, weekdays: []),
                instructions: "Adaugă în aplicația mea de taskuri acțiunile care sunt ale mele (sau fără responsabil) din meetingul „\(notes.title)”, "
                    + "cu termenul dacă e spus și cu linkul notițelor \(savedNotes.documentLink) în descriere. Nu adăuga acțiunile altor oameni.\n"
                    + actions.map { "- \($0)" }.joined(separator: "\n"),
                speaksResult: false
            )
            Task { await runWhenIdle(routine) }
        }
    }

    /// Runs a routine as soon as Macky is free (tries for about 10 minutes).
    private func runWhenIdle(_ routine: Routine) async {
        for _ in 0..<20 {
            if startScheduledRoutine(routine) { return }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    /// The address of the front tab, for browsers that can tell it (asks macOS for Automation permission once).
    private func browserPageURL(applicationName: String) async -> String? {
        let chromiumBrowsers = ["Google Chrome", "Brave Browser", "Microsoft Edge", "Arc", "Chromium", "Vivaldi", "Opera"]
        let script: String
        if chromiumBrowsers.contains(applicationName) {
            script = "tell application \"\(applicationName)\" to return URL of active tab of front window"
        } else if applicationName == "Safari" {
            script = "tell application \"Safari\" to return URL of front document"
        } else {
            return nil
        }
        let result = await screenActionExecutor.runAppleScript(script)
        let address = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && address.hasPrefix("http") ? address : nil
    }

    // MARK: Routines

    /// Starts a scheduled routine unless Macky is busy (then the scheduler tries again shortly).
    func startScheduledRoutine(_ routine: Routine) -> Bool {
        guard !state.isBusy, !audioRecorder.isRecording else { return false }
        stopEverything()
        let interactionIdentifier = startNewInteraction()
        overlayController.beginInteraction(activity: .thinking)
        state = .thinking
        noteNewRequest(routine.name)
        currentRequestWasSpoken = false
        currentInteractionTask = Task {
            await runRoutine(routine, interactionIdentifier: interactionIdentifier)
        }
        return true
    }

    /// "Rulează acum" from Settings.
    func runRoutineNow(_ routine: Routine) {
        routineStore.markRun(routine.id)
        _ = startScheduledRoutine(routine)
    }

    private func runRoutine(_ routine: Routine, interactionIdentifier: UUID) async {
        runningRoutine = routine
        overlayController.setBubbleText("Rutina „\(routine.name)”…")
        let frontmostApplication = accessibilityInspector.frontmostApplicationSnapshot()
        // Routines work with tools (calendar, mail, apps), not with what is on screen.
        await answer(question: routine.requestText, capturedScreens: [], frontmostApplication: frontmostApplication,
                     interactionIdentifier: interactionIdentifier)
    }

    /// Replays a learned procedure. Returns false (and the model takes over) when it cannot run or fails.
    private func runLearnedProcedure(_ procedure: LearnedProcedure, question: String, interactionIdentifier: UUID) async -> Bool {
        let actions = procedure.toolCalls.enumerated().compactMap { index, storedCall in
            ScreenAction(toolCall: storedCall.chatToolCall(identifier: "procedure_\(index)"))
        }
        guard !actions.isEmpty, actions.count == procedure.toolCalls.count, accessibilityInspector.isTrusted else { return false }

        lastQuestionText = question
        lastAnswerText = ""
        isAnswerStreamComplete = false
        showAndSpeak("Sigur!")
        interactionTimings?.firstResponseDate = Date()
        interactionTimings?.wasQuickCommand = true
        // These exact actions were already approved when Macky learned them.
        areActionsApprovedForCurrentQuestion = true

        var descriptions: [String] = []
        var details: [String] = []
        for action in actions {
            let outcome = await perform(action, on: [], coordinateConvention: .imagePixels, stepNumber: 1, interactionIdentifier: interactionIdentifier)
            guard isCurrent(interactionIdentifier) else { return true }
            switch outcome {
            case .done(let description, let resultDetail):
                descriptions.append(description)
                if let resultDetail, !resultDetail.isEmpty { details.append(resultDetail) }
            case .declined, .failed:
                memoryManager.recordProcedureFailure(procedure.id)
                lastAnswerText = ""
                return false
            }
        }
        interactionTimings?.workFinishedDate = Date()
        memoryManager.recordProcedureUse(procedure.id)
        lastReplayedProcedureIdentifier = procedure.id
        let shownAnswer = "⚡ " + (details.isEmpty ? descriptions.joined(separator: ", ") : details.joined(separator: " "))
        lastAnswerText = shownAnswer
        overlayController.setBubbleText(shownAnswer)
        conversationHistory.record(userText: question, assistantText: "Sigur! (Am făcut: \(descriptions.joined(separator: "; ")).)")
        recordInHistory(question: question, answer: shownAnswer, actions: descriptions, route: .procedure)
        isAnswerStreamComplete = true
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        }
        return true
    }

    private func recordInHistory(question: String, answer: String, actions: [String], route: HistoryEntry.Route) {
        let cost = costTracker.totalCostInCredits - costAtRequestStart
        historyStore.record(HistoryEntry(
            question: question,
            answer: answer,
            actions: actions,
            route: route,
            modelIdentifier: route == .model ? lastAnswerModelIdentifier : nil,
            costInDollars: cost > 0 ? cost : nil,
            durationInSeconds: interactionTimings.map { Date().timeIntervalSince($0.releaseDate) }
        ))
    }

    private func cancelListening() {
        activeRecordingPurpose = nil
        _ = audioRecorder.stopRecording()
        drawingOverlayController.clear()
        state = .idle
        overlayController.hideImmediately()
    }

    private struct TranscriptionTimeout: LocalizedError {
        var errorDescription: String? { "a durat prea mult. Încearcă din nou." }
    }

    static func silenceMessage(for recordedAudio: RecordedAudio) -> String {
        if recordedAudio.peakLevel < 0.003 {
            let microphone = recordedAudio.microphoneName.map { "„\($0)”" } ?? "Microfonul"
            return "\(microphone) nu a prins niciun sunet. Alege alt microfon în Setări → Voce și limbă."
        }
        return "Nu am înțeles. Ține apăsat, vorbește, apoi eliberează."
    }

    /// Returns nil (after showing an error) when nothing usable was heard.
    private func transcribe(_ recordedAudio: RecordedAudio, interactionIdentifier: UUID, reportsSilence: Bool = true) async -> String? {
        prepareTranscriber()
        guard let transcriber else {
            fail(with: "Transcrierea nu e pregătită.")
            return nil
        }
        // A microphone that delivered only silence: say so at once instead of letting Whisper invent words.
        if recordedAudio.peakLevel < 0.003 {
            earlyTranscription?.task.cancel()
            earlyTranscription = nil
            if reportsSilence { fail(with: Self.silenceMessage(for: recordedAudio)) }
            return nil
        }
        do {
            let transcript: String
            if let earlyTranscription, speechEndpointDetector.isSilentAfter(sampleIndex: earlyTranscription.sampleCount),
               let earlyTranscript = await earlyTranscription.task.value, !earlyTranscript.isEmpty {
                // Nothing was said after the pause: the transcript made during the pause is complete.
                transcript = earlyTranscript
            } else {
                earlyTranscription?.task.cancel()
                let samples = recordedAudio.samples
                let languageCode = settings.responseLanguage.transcriptionLanguageCode
                let timeoutSeconds = UInt64(max(30, recordedAudio.durationInSeconds * 3))
                // Never leave "Transcriu…" on screen forever.
                transcript = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await transcriber.transcribe(samples: samples, languageCode: languageCode) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                        throw TranscriptionTimeout()
                    }
                    let first = try await group.next() ?? ""
                    group.cancelAll()
                    return first
                }
            }
            earlyTranscription = nil
            guard isCurrent(interactionIdentifier) else { return nil }
            let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper "hears" video outros ("Vă mulțumim pentru vizionare") in silence.
            let looksLikeSilence = cleanedTranscript.isEmpty || cleanedTranscript == "[BLANK_AUDIO]" || TranscriptFilter.isPhantom(cleanedTranscript)
            guard !looksLikeSilence else {
                if reportsSilence { fail(with: Self.silenceMessage(for: recordedAudio)) }
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
        var frontmostApplication = frontmostApplication
        // Apps that hide their selection from Accessibility (some browsers, Electron apps): copy it instead,
        // but only when the request is about text, since copying touches the clipboard.
        let capturesTask = TaskCaptureIntent.matches(question)
        if frontmostApplication.context.selectedText == nil, currentRequestWasSpoken, accessibilityInspector.isTrusted,
           WritingIntent.mentionsText(question) || capturesTask {
            frontmostApplication.context.selectedText = await dictationTextInserter.copySelectedText()
        }
        // "Fă task din asta" in a browser: the page link goes into the task.
        if capturesTask, let applicationName = frontmostApplication.context.applicationName {
            frontmostApplication.context.pageURL = await browserPageURL(applicationName: applicationName)
        }
        let memoryContext = await memoryManager.contextBlock(for: question)
        guard isCurrent(interactionIdentifier) else { return }

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
                    memoryContext: memoryContext,
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
        memoryContext: String?,
        interactionIdentifier: UUID
    ) async throws {
        let actionsEnabled = useToolCalling && settings.actionMode != .disabled
        let memoryToolsEnabled = useToolCalling && settings.memoryEnabled
        var tools: [MackyTool] = useToolCalling ? [.pointAt] : []
        if actionsEnabled { tools += MackyTool.actingTools }
        if memoryToolsEnabled { tools += MackyTool.memoryTools }
        skillLibrary.reloadIfChanged()
        let skills = skillLibrary.skills
        if useToolCalling {
            tools += MackyTool.informationTools.filter { tool in
                if tool == .useSkill { return !skills.isEmpty }
                if tool == .searchGmail || tool == .readEmail {
                    return googleAccountManager.isConnected || !googleAccountManager.additionalGmailAddresses.isEmpty || mailAccountsStore.hasAccounts
                }
                if MackyTool.googleTools.contains(tool) { return googleAccountManager.isConnected }
                if MackyTool.whatsAppTools.contains(tool) { return whatsAppController.isAvailable }
                if MackyTool.pastChatTools.contains(tool) { return !chatArchiveStore.isEmpty }
                if tool == .runAgent { return !(agentStore?.agents.isEmpty ?? true) }
                return true
            }
        }

        // The user's connected apps (MCP servers), e.g. Flowts for tasks and notes.
        let connectedTools = useToolCalling ? await mcpConnectionStore.toolsForRequest(question) : []
        guard isCurrent(interactionIdentifier) else { return }
        let connectedToolDefinitions = connectedTools.map { MCPToolNaming.toolDefinition(serverName: $0.server.name, tool: $0.tool) }
        var connectedApps: [(name: String, instructions: String)] = []
        for entry in connectedTools where !connectedApps.contains(where: { $0.name == entry.server.name }) {
            connectedApps.append((entry.server.name, entry.server.instructions))
        }

        let systemPrompt = MackyPrompt.systemPrompt(
            language: settings.responseLanguage,
            pointingMode: useToolCalling ? .toolCall : .textTag,
            actionsEnabled: actionsEnabled,
            memoryEnabled: memoryToolsEnabled,
            informationToolsEnabled: useToolCalling,
            skillsSection: useToolCalling ? SkillCatalog.promptSection(for: skills) : nil,
            connectedAppsSection: MackyPrompt.connectedAppsSection(apps: connectedApps)
        )
        var userText = MackyPrompt.userMessageText(
            question: question,
            screenshots: capturedScreens.map(\.promptDescription),
            frontmostApplication: frontmostApplication.context,
            coordinateConvention: coordinateConvention,
            userMarkings: Self.markings(from: userDrawingStrokes, on: capturedScreens, coordinateConvention: coordinateConvention),
            memoryContext: memoryContext
        )
        if TaskCaptureIntent.matches(question) {
            // Apps whose tools create tasks (e.g. Flowts); otherwise Reminders.
            let taskAppNames = connectedApps.map(\.name).filter { name in
                connectedTools.contains { $0.server.name == name && $0.tool.name.lowercased().contains("task") }
            }
            userText += "\n\n" + TaskCaptureIntent.instruction(taskAppNames: taskAppNames)
        }
        let userParts: [ChatContentPart] = [.text(userText)] + capturedScreens.map { .jpegImage(base64EncodedData: $0.jpegData.base64EncodedString()) }
        conversationHistory.maximumRememberedExchanges = max(0, settings.rememberedExchangeCount)
        var messages = conversationHistory.messagesForRequest(systemPrompt: systemPrompt, currentUserParts: userParts)

        var currentScreens = capturedScreens
        var spokenAnswerParts: [String] = []
        var pointedLabels: [String] = []
        var performedActionDescriptions: [String] = []
        // For learning: what was done, and whether anything went wrong.
        var executedToolCalls: [ChatToolCall] = []
        var failureReasons: [String] = []
        var whatsAppSendFailed = false
        var taskEndedCleanly = true
        isAnswerStreamComplete = false
        // The user set up a routine's actions themselves: no confirmation cards.
        areActionsApprovedForCurrentQuestion = runningRoutine != nil

        agentLoop: for stepNumber in 1...Self.maximumAgentSteps {
            // Only the first response is spoken live (the answer, or the short "Sigur, mă ocup!").
            // Later steps of a task stay quiet unless they end the task with something to say.
            let isFirstStep = stepNumber == 1
            let stepResult = try await streamModelStep(
                messages: messages,
                tools: tools,
                extraToolDefinitions: connectedToolDefinitions,
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

            let requestedActions = stepResult.toolCalls.compactMap(resolvedAction(for:))
            let modelSaysTaskIsDone = stepResult.toolCalls.contains { $0.name == MackyTool.taskDone.rawValue }
            let onlyScreenlessOperations = !requestedActions.isEmpty && requestedActions.allSatisfy(\.needsNoScreen)
            guard (actionsEnabled || onlyScreenlessOperations), !requestedActions.isEmpty else {
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
                } else if anyActionFailed && resolvedAction(for: toolCall) != nil {
                    resultText = "Skipped because an earlier action failed."
                } else if let action = resolvedAction(for: toolCall) {
                    switch await perform(action, on: currentScreens, coordinateConvention: coordinateConvention, stepNumber: stepNumber, interactionIdentifier: interactionIdentifier) {
                    case .done(let description, let resultDetail):
                        if !action.isMemoryOperation { performedActionDescriptions.append(description) }
                        executedToolCalls.append(toolCall)
                        resultText = resultDetail.map { $0.isEmpty ? "Done." : "Done. Result: \($0)" } ?? "Done."
                    case .declined:
                        userDeclined = true
                        taskEndedCleanly = false
                        resultText = "The user declined this action."
                    case .failed(let reason):
                        anyActionFailed = true
                        // A WhatsApp message that could not be sent ends the task: no improvising in other apps.
                        if case .whatsAppSend = action { whatsAppSendFailed = true }
                        taskEndedCleanly = false
                        failureReasons.append("\(action.userFacingDescription): \(reason)")
                        resultText = "Failed: \(reason)"
                    }
                } else if toolCall.name == MackyTool.pointAt.rawValue {
                    resultText = "Shown to the user."
                } else if toolCall.name == MackyTool.taskDone.rawValue {
                    executedToolCalls.append(toolCall)
                    resultText = "OK."
                } else {
                    resultText = "Invalid tool call arguments."
                }
                guard isCurrent(interactionIdentifier) else { return }
                messages.append(.toolResult(for: toolCall, result: resultText))
            }

            if whatsAppSendFailed { break agentLoop }

            // The model said these actions finish the task: no extra screenshot and round trip.
            if modelSaysTaskIsDone && !userDeclined && !anyActionFailed {
                break agentLoop
            }

            // Memory, web and skill tools need no new screenshot. After "remember"/"forget" with an answer already given,
            // the turn is over; after tools that return information the model needs one more step to answer with it.
            if onlyScreenlessOperations {
                let needsAnotherStep = stepResult.visibleText.isEmpty || requestedActions.contains(where: \.returnsInformation)
                if !needsAnotherStep || stepNumber == Self.maximumAgentSteps { break agentLoop }
                state = .thinking
                overlayController.setActivity(.thinking)
                continue agentLoop
            }

            if userDeclined {
                let declinedAnswer = "Bine, nu fac asta."
                spokenAnswerParts.append(declinedAnswer)
                showAndSpeak(declinedAnswer)
                break agentLoop
            }
            if stepNumber == Self.maximumAgentSteps {
                taskEndedCleanly = false
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
            } else if let failure = failureReasons.last {
                finalAnswer = "Nu am reușit: \(failure)"
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
        // Answers invite a reply; actions (music, opening apps) do not, unless Macky asked something.
        shouldListenForFollowUp = performedActionDescriptions.isEmpty || finalAnswer.hasSuffix("?")
        if let runningRoutine {
            recordInHistory(question: "Rutina „\(runningRoutine.name)”", answer: finalAnswer, actions: performedActionDescriptions, route: .routine)
        } else {
            recordInHistory(question: question, answer: finalAnswer, actions: performedActionDescriptions, route: .model)
            memoryManager.recordExchange(question: question, answer: finalAnswer, actions: performedActionDescriptions, failures: failureReasons)
        }
        if runningRoutine == nil, taskEndedCleanly, memoryManager.recordSuccessfulRun(request: question, toolCalls: executedToolCalls) != nil {
            // Shown, not spoken: next time this request runs instantly.
            overlayController.setBubbleText((lastAnswerText.isEmpty ? finalAnswer : lastAnswerText) + " ⚡ Am învățat: data viitoare fac asta instant.")
        }
        isAnswerStreamComplete = true

        guard isCurrent(interactionIdentifier) else { return }
        if !speechSpeaker.isSpeaking {
            finishInteraction()
        } else {
            finishWhenSpeechEnds(interactionIdentifier: interactionIdentifier)
        }
    }

    /// Safety net: whatever state the task left behind, once Macky stops talking the bubble and cursor go away.
    private func finishWhenSpeechEnds(interactionIdentifier: UUID) {
        Task { @MainActor [weak self] in
            for _ in 0..<360 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isCurrent(interactionIdentifier) else { return }
                guard self.isAnswerStreamComplete else { return }
                if self.state == .idle || self.state == .listening || self.state == .transcribing { return }
                if !self.speechSpeaker.isSpeaking {
                    self.finishInteraction()
                    return
                }
            }
        }
    }

    private struct ModelStepResult {
        var visibleText: String
        var pointingInstructions: [PointingInstruction]
        var toolCalls: [ChatToolCall]
    }

    /// Streams one model response: shows and speaks text as it arrives, collects tool calls.
    /// Macky's own tools, or a connected app's.
    private func resolvedAction(for toolCall: ChatToolCall) -> ScreenAction? {
        ScreenAction(toolCall: toolCall) ?? mcpConnectionStore.action(for: toolCall)
    }

    private func streamModelStep(
        messages: [ChatMessage],
        tools: [MackyTool],
        extraToolDefinitions: [[String: Any]] = [],
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
            disableReasoning: disableReasoning,
            cacheSystemPrompt: OpenRouterRequestBuilder.needsExplicitPromptCaching(modelIdentifier: modelIdentifier),
            extraToolDefinitions: extraToolDefinitions
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
        switch action {
        case .remember(let kind, let subject, let content):
            return .done(action.userFacingDescription, resultDetail: await memoryManager.remember(kind: kind, subject: subject, content: content))
        case .forget(let query):
            return .done(action.userFacingDescription, resultDetail: await memoryManager.forget(query: query))
        case .recall(let query):
            return .done(action.userFacingDescription, resultDetail: await memoryManager.recall(query: query))
        case .useSkill(let name):
            guard let skill = skillLibrary.skill(named: name) else {
                return .failed("No skill is called \(name). Available: \(skillLibrary.skills.map(\.name).joined(separator: ", ")).")
            }
            return .done(action.userFacingDescription, resultDetail: SkillCatalog.toolResult(for: skill))
        case .webSearch(let query):
            guard let apiKey = apiKeyStore.apiKey() else { return .failed("No OpenRouter key.") }
            overlayController.setBubbleText("Caut pe web: \(query)…")
            let result = await backgroundAgentManager.webResearchService.search(query, apiKey: apiKey)
            if let cost = result.cost { costTracker.record(TokenUsage(promptTokens: 0, completionTokens: 0, costInCredits: cost)) }
            return .done(action.userFacingDescription, resultDetail: result.text)
        case .fetchURL(let address):
            return .done(action.userFacingDescription, resultDetail: await backgroundAgentManager.webResearchService.readableText(from: address, maximumCharacters: 8000))
        case .searchFiles(let query, let kind):
            return .done(action.userFacingDescription, resultDetail: await localFileSearch.search(query, kind: kind))
        case .readFile(let path):
            return .done(action.userFacingDescription, resultDetail: FileTextReader.readLocalFile(atPath: path))
        case .searchGmail(let query, let maximumResults, let account):
            overlayController.setBubbleText("Caut în email…")
            var lines = await googleAccountManager.searchGmailLines(query: query, maximumResults: maximumResults, accountFilter: account)
            lines += await mailAccountsStore.search(query: query, maximumResults: maximumResults, accountFilter: account)
            return .done(action.userFacingDescription, resultDetail: lines.isEmpty ? "No emails match \"\(query)\"." : lines.joined(separator: "\n"))
        case .readEmail(let identifier):
            if identifier.hasPrefix("imap:") {
                return .done(action.userFacingDescription, resultDetail: await mailAccountsStore.read(identifier: identifier))
            }
            return .done(action.userFacingDescription, resultDetail: await googleAccountManager.readEmail(identifier: identifier))
        case .searchDrive(let query):
            overlayController.setBubbleText("Caut în Google Drive…")
            return .done(action.userFacingDescription, resultDetail: await googleAccountManager.searchDrive(query: query))
        case .readDriveFile(let identifier):
            return .done(action.userFacingDescription, resultDetail: await googleAccountManager.readDriveFile(identifier: identifier))
        case .runAgent(let name, let request):
            guard let agentStore, let agent = agentStore.agent(named: name) else {
                let names = agentStore?.agents.map(\.name).joined(separator: ", ") ?? ""
                return .failed("No agent is called \(name). The user's agents: \(names).")
            }
            if agentStore.isRunning(agent.id) {
                return .done(action.userFacingDescription, resultDetail: "\(agent.name) is already working.")
            }
            agentStore.run(agent.id, extraRequest: request)
            return .done(action.userFacingDescription, resultDetail: "\(agent.name) started in the background.")
        case .searchPastChats(let query):
            return .done(action.userFacingDescription, resultDetail: chatArchiveStore.search(query))
        case .readPastChat(let title):
            guard let text = chatArchiveStore.read(title: title) else {
                return .failed("No imported Claude or ChatGPT chat or project is called \(title).")
            }
            return .done(action.userFacingDescription, resultDetail: text)
        case .whatsAppChats(let unreadOnly, let limit):
            do {
                return .done(action.userFacingDescription, resultDetail: WhatsAppKit.chatListText(try whatsAppController.chats(unreadOnly: unreadOnly, limit: limit)))
            } catch {
                return .failed(error.localizedDescription)
            }
        case .whatsAppRead(let chat, let limit):
            do {
                guard let conversation = try whatsAppController.messages(inChatNamed: chat, limit: limit) else {
                    return .failed("No WhatsApp chat is called \(chat).")
                }
                return .done(action.userFacingDescription, resultDetail: "Chat: \(conversation.chat.name)\n" + WhatsAppKit.transcript(conversation.messages))
            } catch {
                return .failed(error.localizedDescription)
            }
        case .whatsAppSearch(let query):
            do {
                return .done(action.userFacingDescription, resultDetail: WhatsAppKit.transcript(try whatsAppController.search(query)))
            } catch {
                return .failed(error.localizedDescription)
            }
        case .externalTool(let serverName, let toolName, let argumentsJSON, let needsConfirmation):
            // Only deleting asks first; creating and editing in the user's own app is what they asked for.
            if needsConfirmation && settings.actionMode == .askFirst && !areActionsApprovedForCurrentQuestion {
                let answer = await actionConfirmationController.requestConfirmation(
                    actionDescription: action.userFacingDescription, stepNumber: stepNumber, nearPoint: nil
                )
                guard isCurrent(interactionIdentifier) else { return .declined }
                switch answer {
                case .declined: return .declined
                case .approvedForRestOfTask: areActionsApprovedForCurrentQuestion = true
                case .approved: break
                }
            }
            let result = await mcpConnectionStore.callTool(serverName: serverName, toolName: toolName, argumentsJSON: argumentsJSON)
            return result.isError ? .failed(result.text) : .done(action.userFacingDescription, resultDetail: result.text)
        default:
            break
        }
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

        // Reading the calendar or starting a background job changes nothing on screen: no need to ask.
        var needsConfirmation = !action.isReadOnly
        if case .startBackgroundTask = action { needsConfirmation = false }
        // Replacing selected text is what the user just asked for, and ⌘Z undoes it.
        if case .replaceSelection = action { needsConfirmation = false }
        if settings.actionMode == .askFirst && !areActionsApprovedForCurrentQuestion && needsConfirmation {
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
        case .system(let systemCommand):
            return Self.actionOutcome(await systemController.perform(systemCommand), description: action.userFacingDescription)
        case .createEvent(let request):
            return Self.actionOutcome(await personalDataController.createEvent(request), description: action.userFacingDescription)
        case .listEvents(let fromDate, let toDate):
            return Self.actionOutcome(await personalDataController.listEvents(from: fromDate, to: toDate), description: action.userFacingDescription)
        case .createReminder(let title, let dueDate, let notes):
            return Self.actionOutcome(await personalDataController.createReminder(title: title, dueDate: dueDate, notes: notes), description: action.userFacingDescription)
        case .listReminders(let limit):
            return Self.actionOutcome(await personalDataController.listReminders(limit: limit), description: action.userFacingDescription)
        case .createNote(let title, let body):
            return Self.actionOutcome(await notesController.createNote(title: title, body: body), description: action.userFacingDescription)
        case .arrangeWindow(let applicationName, let layout):
            return Self.actionOutcome(await windowArranger.arrange(applicationName: applicationName, layout: layout), description: action.userFacingDescription)
        case .startBackgroundTask(let goal):
            backgroundAgentManager.start(goal: goal)
            return .done(action.userFacingDescription, resultDetail: "The background agent started. It will report when it is done; tell the user briefly.")
        case .remember, .forget, .recall, .useSkill, .webSearch, .fetchURL,
             .searchFiles, .readFile, .searchGmail, .readEmail, .searchDrive, .readDriveFile, .externalTool,
             .whatsAppChats, .whatsAppRead, .whatsAppSearch, .searchPastChats, .readPastChat, .runAgent:
            break
        case .whatsAppSend(let recipient, let text):
            do {
                return .done(action.userFacingDescription, resultDetail: try await whatsAppController.send(to: recipient, text: text))
            } catch {
                return .failed(error.localizedDescription)
            }
        case .openFile(let path):
            let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: fileURL.path), NSWorkspace.shared.open(fileURL) else {
                return .failed("Could not open \(path).")
            }
        case .replaceSelection(let text):
            dictationTextInserter.insert(text)
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .done(action.userFacingDescription, resultDetail: "The selected text was replaced.")
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

    private static func actionOutcome(_ outcome: IntegrationOutcome, description: String) -> ActionOutcome {
        outcome.succeeded ? .done(description, resultDetail: outcome.message) : .failed(outcome.message)
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
        guard settings.speakResponses, runningRoutine?.speaksResult != false else { return }
        speechSpeaker.speak(
            SpeechTextCleaner.cleanForSpeech(sentence),
            voiceIdentifier: settings.speechVoiceIdentifier,
            languageCode: settings.responseLanguage.transcriptionLanguageCode,
            rateMultiplier: settings.speechRateMultiplier,
            neuralVoice: neuralVoiceForAnswers
        )
    }

    /// The Edge neural voice to use, or nil for the Mac voice.
    private var neuralVoiceForAnswers: String? {
        guard settings.speechEngine == .neural else { return nil }
        let chosenVoice = settings.neuralVoiceIdentifier.isEmpty ? EdgeTTSProtocol.romanianVoices[0].id : settings.neuralVoiceIdentifier
        // A Romanian voice reading English sounds wrong, and the other way around.
        if settings.responseLanguage == .english && chosenVoice.hasPrefix("ro-") { return EdgeTTSProtocol.englishVoices[0].id }
        if settings.responseLanguage == .romanian && !chosenVoice.hasPrefix("ro-") { return EdgeTTSProtocol.romanianVoices[0].id }
        return chosenVoice
    }

    /// Fetches the audio of the usual short replies in advance, so they play instantly.
    func prepareNeuralVoice() {
        guard let neuralVoiceForAnswers else { return }
        speechSpeaker.prepareShortPhrases(
            ["Sigur!", "Sigur, pornesc acum!", "Sigur, mă ocup!", "Sigur, mă ocup în fundal!", "Gata.", "Am reținut."],
            neuralVoice: neuralVoiceForAnswers, rateMultiplier: settings.speechRateMultiplier
        )
    }

    private func speechQueueDrained() {
        // After a task the state can still read "thinking": finish anyway once the answer is complete.
        guard isAnswerStreamComplete, state == .speaking || state == .thinking else { return }
        finishInteraction()
    }

    private func finishInteraction() {
        state = .idle
        drawingOverlayController.clear()
        if let interactionTimings {
            lastTimingSummary = interactionTimings.summary(finishedDate: Date())
            self.interactionTimings = nil
        }
        let continuesConversation = shouldListenForFollowUp && currentRequestWasSpoken && settings.followUpListeningEnabled
        shouldListenForFollowUp = false
        if continuesConversation && startFollowUpListening(afterAnswer: lastAnswerText) {
            return
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
