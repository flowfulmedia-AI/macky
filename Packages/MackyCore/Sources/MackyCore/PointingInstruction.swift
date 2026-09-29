import Foundation

/// A request from the model to point at something on a screenshot.
/// `x` and `y` are in the model's coordinate convention; see `CoordinateConvention`.
public struct PointingInstruction: Equatable, Sendable {
    public var screenNumber: Int
    public var x: Double
    public var y: Double
    public var label: String

    public init(screenNumber: Int, x: Double, y: Double, label: String) {
        self.screenNumber = screenNumber
        self.x = x
        self.y = y
        self.label = label
    }

    /// Parses the arguments of a `point_at` tool call. Some models send numbers as strings,
    /// so both forms are accepted.
    public init?(toolArgumentsJSON: String) {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = OpenRouterStreamDecoder.doubleValue(arguments["x"]),
              let y = OpenRouterStreamDecoder.doubleValue(arguments["y"]) else {
            return nil
        }
        let screenNumber = OpenRouterStreamDecoder.integerValue(arguments["screen"]) ?? 1
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(screenNumber: max(1, screenNumber), x: x, y: y, label: label)
    }

    /// Parses the body of a fallback text tag, e.g. `point:1,640,400,Export`
    /// (screen, x, y, label) or `point:640,400,Export` (screen defaults to 1).
    public init?(fallbackTagBody: String) {
        let lowercasedBody = fallbackTagBody.lowercased()
        guard lowercasedBody.hasPrefix("point") else { return nil }
        // Read up to three leading numbers separated by commas, colons or spaces; the rest is the label.
        let separators = CharacterSet(charactersIn: ",: ")
        var remainder = Substring(fallbackTagBody.dropFirst("point".count))
        var numbers: [Double] = []
        while numbers.count < 3 {
            let withoutSeparators = remainder.drop { character in
                character.unicodeScalars.allSatisfy { separators.contains($0) }
            }
            guard let numberRange = withoutSeparators.range(of: #"^-?\d+(\.\d+)?"#, options: .regularExpression),
                  let number = Double(withoutSeparators[numberRange]) else { break }
            numbers.append(number)
            remainder = withoutSeparators[numberRange.upperBound...]
        }
        let label = remainder.trimmingCharacters(in: separators)
        switch numbers.count {
        case 3:
            self.init(screenNumber: max(1, Int(numbers[0])), x: numbers[1], y: numbers[2], label: label)
        case 2:
            self.init(screenNumber: 1, x: numbers[0], y: numbers[1], label: label)
        default:
            return nil
        }
    }
}

/// Removes fallback `[[point:...]]` tags from streamed text while collecting them.
/// Used for models that cannot call tools. Text that might be the start of a tag is
/// held back until it is clear whether it is a tag, so tags are never spoken aloud.
public struct PointTagStreamFilter {
    public struct Output: Equatable {
        public var visibleText: String
        public var pointingInstructions: [PointingInstruction]
    }

    private static let tagOpening = "[["
    private static let tagClosing = "]]"
    /// A tag longer than this is treated as normal text so a stray "[[" cannot swallow the whole answer.
    private static let maximumTagLength = 200

    private var heldBackText = ""

    public init() {}

    public mutating func consume(_ newText: String) -> Output {
        heldBackText += newText
        var visibleText = ""
        var pointingInstructions: [PointingInstruction] = []

        while true {
            guard let openingRange = heldBackText.range(of: Self.tagOpening) else {
                // Keep a trailing "[" in case the next chunk completes "[[".
                if heldBackText.hasSuffix("[") {
                    visibleText += heldBackText.dropLast()
                    heldBackText = "["
                } else {
                    visibleText += heldBackText
                    heldBackText = ""
                }
                break
            }

            visibleText += heldBackText[..<openingRange.lowerBound]
            let textFromOpening = String(heldBackText[openingRange.lowerBound...])

            guard let closingRange = textFromOpening.range(of: Self.tagClosing) else {
                if textFromOpening.count > Self.maximumTagLength {
                    visibleText += textFromOpening
                    heldBackText = ""
                } else {
                    heldBackText = textFromOpening
                }
                break
            }

            let tagBody = String(textFromOpening[textFromOpening.index(textFromOpening.startIndex, offsetBy: Self.tagOpening.count)..<closingRange.lowerBound])
            if let instruction = PointingInstruction(fallbackTagBody: tagBody.trimmingCharacters(in: .whitespaces)) {
                pointingInstructions.append(instruction)
            } else {
                visibleText += textFromOpening[..<closingRange.upperBound]
            }
            heldBackText = String(textFromOpening[closingRange.upperBound...])
        }

        return Output(visibleText: visibleText, pointingInstructions: pointingInstructions)
    }

    /// Returns whatever is still held back once the stream has ended.
    public mutating func flush() -> String {
        defer { heldBackText = "" }
        return heldBackText
    }
}
