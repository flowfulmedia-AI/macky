import AppKit
import MackyCore
import SwiftUI

/// Measures how precisely a model points: it shows numbered targets, asks the model to point at
/// one, and compares the answer with the target's real position (in screen points).
/// No Accessibility snapping is applied, so this measures the model itself.
@MainActor
final class CalibrationRunner: ObservableObject {
    struct CalibrationTarget: Identifiable {
        let id: Int
        /// Position inside the calibration canvas, 0...1 on both axes, origin top-left.
        let normalizedPosition: CGPoint
    }

    struct TrialResult: Identifiable {
        let id = UUID()
        let modelIdentifier: String
        let targetNumber: Int
        let errorInPoints: Double?
        let latencyInSeconds: Double
        let costInCredits: Double?
        let note: String?
    }

    @Published private(set) var targets: [CalibrationTarget] = []
    @Published private(set) var results: [TrialResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Alege un model și apasă Testează. Nu muta fereastra în timpul testului."
    @Published private(set) var activeTargetNumber: Int?
    /// Where the model pointed, in canvas coordinates (top-left origin).
    @Published private(set) var lastPredictedCanvasPoint: CGPoint?
    @Published var modelIdentifier: String

    weak var window: NSWindow?
    var canvasSize: CGSize = .zero

    private let settings: AppSettings
    private let apiKeyStore: OpenRouterAPIKeyStore
    private let modelCatalogStore: ModelCatalogStore
    private let openRouterClient: OpenRouterClient
    private let screenCaptureService = ScreenCaptureService()

    init(settings: AppSettings, apiKeyStore: OpenRouterAPIKeyStore, modelCatalogStore: ModelCatalogStore, openRouterClient: OpenRouterClient) {
        self.settings = settings
        self.apiKeyStore = apiKeyStore
        self.modelCatalogStore = modelCatalogStore
        self.openRouterClient = openRouterClient
        self.modelIdentifier = settings.activeModelIdentifier
        shuffleTargets()
    }

    func shuffleTargets() {
        // A 4x3 grid with random jitter, kept below the control bar at the top.
        var newTargets: [CalibrationTarget] = []
        var targetNumber = 1
        for row in 0..<3 {
            for column in 0..<4 {
                let x = 0.1 + Double(column) * 0.26 + Double.random(in: -0.06...0.06)
                let y = 0.36 + Double(row) * 0.22 + Double.random(in: -0.05...0.05)
                newTargets.append(CalibrationTarget(id: targetNumber, normalizedPosition: CGPoint(x: x, y: y)))
                targetNumber += 1
            }
        }
        targets = newTargets.shuffled().enumerated().map { index, target in
            CalibrationTarget(id: index + 1, normalizedPosition: target.normalizedPosition)
        }
        lastPredictedCanvasPoint = nil
    }

    func averageError(forModelIdentifier modelIdentifier: String) -> Double? {
        let errors = results.filter { $0.modelIdentifier == modelIdentifier }.compactMap(\.errorInPoints)
        guard !errors.isEmpty else { return nil }
        return errors.reduce(0, +) / Double(errors.count)
    }

    var testedModelIdentifiers: [String] {
        var seenIdentifiers: [String] = []
        for result in results where !seenIdentifiers.contains(result.modelIdentifier) {
            seenIdentifiers.append(result.modelIdentifier)
        }
        return seenIdentifiers
    }

    func runTrials(count trialCount: Int = 5) async {
        guard !isRunning else { return }
        guard let apiKey = apiKeyStore.apiKey() else {
            statusText = "Adaugă întâi cheia OpenRouter în Setări."
            return
        }
        guard let window, canvasSize.width > 0 else { return }
        let modelIdentifier = self.modelIdentifier.trimmingCharacters(in: .whitespaces)
        guard !modelIdentifier.isEmpty else {
            statusText = "Scrie identificatorul unui model."
            return
        }

        isRunning = true
        defer {
            isRunning = false
            activeTargetNumber = nil
        }

        for trialNumber in 1...trialCount {
            guard let target = targets.randomElement() else { return }
            activeTargetNumber = target.id
            statusText = "Test \(trialNumber)/\(trialCount): îi cer lui \(modelIdentifier) să arate ținta \(target.id)…"
            let trialResult = await runSingleTrial(target: target, modelIdentifier: modelIdentifier, apiKey: apiKey, window: window)
            results.insert(trialResult, at: 0)
        }

        if let averageError = averageError(forModelIdentifier: modelIdentifier) {
            statusText = String(format: "Gata. Eroare medie pentru %@: %.0f puncte (sub ~15 e foarte bine, peste ~40 ratează butoanele mici).", modelIdentifier, averageError)
        } else {
            statusText = "Gata, dar modelul nu a indicat nimic. Încearcă alt model sau altă convenție de coordonate."
        }
    }

    private func runSingleTrial(target: CalibrationTarget, modelIdentifier: String, apiKey: String, window: NSWindow) async -> TrialResult {
        let startDate = Date()
        func failedResult(_ note: String) -> TrialResult {
            TrialResult(modelIdentifier: modelIdentifier, targetNumber: target.id, errorInPoints: nil,
                        latencyInSeconds: Date().timeIntervalSince(startDate), costInCredits: nil, note: note)
        }

        let capturedScreens: [CapturedScreen]
        do {
            capturedScreens = try await screenCaptureService.captureScreens(
                includeAllScreens: false,
                maximumLongEdge: settings.maximumScreenshotLongEdge,
                excludedBundleIdentifiers: [],
                alwaysIncludedWindowNumbers: [window.windowNumber]
            )
        } catch {
            return failedResult("Captură eșuată: \(error.localizedDescription)")
        }
        guard let screen = capturedScreens.first else { return failedResult("Nicio captură") }

        let coordinateConvention = settings.coordinateConvention(forModelIdentifier: modelIdentifier)
        var useToolCalling = settings.shouldUseToolCalling(forModelIdentifier: modelIdentifier, catalogModel: modelCatalogStore.model(withIdentifier: modelIdentifier))

        for attemptNumber in 1...2 {
            do {
                let systemPrompt = MackyPrompt.systemPrompt(language: .english, pointingMode: useToolCalling ? .toolCall : .textTag)
                let userText = MackyPrompt.userMessageText(
                    question: "In the window titled \"Calibrare Macky\", point at the circle labeled \(target.id). Reply with one short sentence.",
                    screenshots: [screen.promptDescription],
                    frontmostApplication: nil,
                    coordinateConvention: coordinateConvention
                )
                let requestBody = try OpenRouterRequestBuilder.makeChatCompletionBody(
                    modelIdentifier: modelIdentifier,
                    messages: [
                        ChatMessage(role: .system, text: systemPrompt),
                        ChatMessage(role: .user, parts: [.text(userText), .jpegImage(base64EncodedData: screen.jpegData.base64EncodedString())])
                    ],
                    tools: useToolCalling ? [.pointAt] : [],
                    coordinateConvention: coordinateConvention
                )
                let response = try await openRouterClient.collectChatCompletion(requestBody: requestBody, apiKey: apiKey, purpose: .calibration)
                let latency = Date().timeIntervalSince(startDate)

                var instruction = response.toolCalls
                    .first { $0.name == OpenRouterRequestBuilder.pointAtToolName }
                    .flatMap { PointingInstruction(toolArgumentsJSON: $0.argumentsJSON) }
                if instruction == nil {
                    var tagFilter = PointTagStreamFilter()
                    instruction = tagFilter.consume(response.text).pointingInstructions.first
                }
                guard let instruction else {
                    return TrialResult(modelIdentifier: modelIdentifier, targetNumber: target.id, errorInPoints: nil,
                                       latencyInSeconds: latency, costInCredits: response.usage?.costInCredits, note: "Nu a indicat nimic")
                }

                let imagePixel = coordinateConvention.imagePixelPoint(modelX: instruction.x, modelY: instruction.y, imagePixelSize: screen.geometry.imagePixelSize)
                let predictedGlobalPoint = ScreenGeometry.appKitGlobalPoint(fromImagePixel: imagePixel, on: screen.geometry)
                let targetGlobalPoint = globalPoint(ofCanvasPoint: canvasPoint(of: target), in: window)
                lastPredictedCanvasPoint = canvasPoint(ofGlobalPoint: predictedGlobalPoint, in: window)

                return TrialResult(
                    modelIdentifier: modelIdentifier,
                    targetNumber: target.id,
                    errorInPoints: ScreenGeometry.distance(from: predictedGlobalPoint, to: targetGlobalPoint),
                    latencyInSeconds: latency,
                    costInCredits: response.usage?.costInCredits,
                    note: useToolCalling ? nil : "prin text"
                )
            } catch let apiError as OpenRouterAPIError where apiError.indicatesToolCallingUnsupported && useToolCalling && attemptNumber == 1 {
                settings.markModelWithoutToolCalling(modelIdentifier)
                useToolCalling = false
            } catch {
                return failedResult(CompanionSession.userFacingMessage(for: error))
            }
        }
        return failedResult("Eroare necunoscută")
    }

    func canvasPoint(of target: CalibrationTarget) -> CGPoint {
        CGPoint(x: target.normalizedPosition.x * canvasSize.width, y: target.normalizedPosition.y * canvasSize.height)
    }

    /// The canvas fills the window's content area, whose top-left is the canvas origin.
    private func globalPoint(ofCanvasPoint canvasPoint: CGPoint, in window: NSWindow) -> CGPoint {
        let contentFrame = window.contentRect(forFrameRect: window.frame)
        return CGPoint(x: contentFrame.minX + canvasPoint.x, y: contentFrame.maxY - canvasPoint.y)
    }

    private func canvasPoint(ofGlobalPoint globalPoint: CGPoint, in window: NSWindow) -> CGPoint {
        let contentFrame = window.contentRect(forFrameRect: window.frame)
        return CGPoint(x: globalPoint.x - contentFrame.minX, y: contentFrame.maxY - globalPoint.y)
    }
}

struct CalibrationView: View {
    @ObservedObject var runner: CalibrationRunner
    @ObservedObject var settings: AppSettings

    private static let targetDiameter: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)

                ForEach(runner.targets) { target in
                    let center = CGPoint(x: target.normalizedPosition.x * geometry.size.width, y: target.normalizedPosition.y * geometry.size.height)
                    ZStack {
                        Circle()
                            .fill(target.id == runner.activeTargetNumber ? MackyDesign.accent.opacity(0.25) : Color.primary.opacity(0.08))
                        Circle()
                            .stroke(Color.primary.opacity(0.6), lineWidth: 2)
                        Text("\(target.id)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .frame(width: Self.targetDiameter, height: Self.targetDiameter)
                    .position(center)
                }

                if let predictedPoint = runner.lastPredictedCanvasPoint {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.red)
                        .position(predictedPoint)
                }

                controlBar
                    .padding(12)
            }
            .onAppear { runner.canvasSize = geometry.size }
            .onChange(of: geometry.size) { newSize in runner.canvasSize = newSize }
        }
        .frame(minWidth: 860, minHeight: 640)
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("model", text: $runner.modelIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                Button("Rapid") { runner.modelIdentifier = settings.fastModelIdentifier }
                Button("Puternic") { runner.modelIdentifier = settings.powerfulModelIdentifier }
                Button(runner.isRunning ? "Testez…" : "Testează 5 ținte") {
                    Task { await runner.runTrials() }
                }
                .disabled(runner.isRunning)
                .keyboardShortcut(.defaultAction)
                Button("Amestecă") { runner.shuffleTargets() }
                    .disabled(runner.isRunning)
            }
            Text(runner.statusText)
                .font(.callout)
                .foregroundColor(.secondary)
            if !runner.results.isEmpty {
                resultsSummary
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }

    private var resultsSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(runner.testedModelIdentifiers, id: \.self) { modelIdentifier in
                let average = runner.averageError(forModelIdentifier: modelIdentifier)
                Text("\(modelIdentifier): eroare medie \(average.map { String(format: "%.0f pt", $0) } ?? "—")")
                    .font(.caption.monospaced())
            }
            if let latestResult = runner.results.first {
                Text("Ultimul test: ținta \(latestResult.targetNumber) · \(latestResult.errorInPoints.map { String(format: "%.0f pt", $0) } ?? "—") · \(String(format: "%.1fs", latestResult.latencyInSeconds))\(latestResult.costInCredits.map { " · " + SessionCostTracker.formatCredits($0) } ?? "")\(latestResult.note.map { " · " + $0 } ?? "")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
