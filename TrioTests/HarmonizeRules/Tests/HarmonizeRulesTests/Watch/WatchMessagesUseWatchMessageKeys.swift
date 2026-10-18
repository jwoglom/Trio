import Foundation
import Harmonize
import HarmonizeSemantics
import SwiftSyntax
import Testing

@Suite struct WatchMessagesUseWatchMessageKeys {
    @Test func phoneAndWatchNameEveryMessageKeyInWatchMessageKeys() {
        let scopes = [
            TrioHarmonize.productionCode.on("Trio/Sources/Services/WatchManager").sources(),
            TrioHarmonize.watchExtension.sources()
        ]
        for files in scopes {
            #expect(!files.isEmpty, "A watch scope finds no files: its folder moved, or .harmonize.yaml excludes it")
        }

        let literalKeys: [Occurrence<Syntax>] = scopes.joined().flatMap { file in
            let dictionaryKeys = file.occurrences(of: DictionaryElementSyntax.self) { "\($0.key.trimmedDescription):" }
                .filter { Self.isLiteralKey($0.node) }
            let subscriptKeys = file.occurrences(of: SubscriptCallExprSyntax.self) { $0.trimmedDescription }
                .filter { Self.isLiteralKeyOnAMessage($0.node) }
            return dictionaryKeys.map(\.erased) + subscriptKeys.map(\.erased)
        }

        literalKeys.assertEmpty(rule: Self.rule)
    }

    // oref's forecast series names: the keys inside the forecastLines value and of the chart colours keyed by them, data
    // the watch iterates over, not a key either side looks a message up by.
    private static let forecastSeries: Set<String> = ["iob", "zt", "cob", "uam"]

    private static let messageNames = ["message", "userInfo", "payload", "dictionary", "data", "context"]

    private static func isLiteralKey(_ element: DictionaryElementSyntax) -> Bool {
        guard let literal = element.key.as(StringLiteralExprSyntax.self) else { return false }
        return !forecastSeries.contains(text(of: literal) ?? "")
    }

    private static func isLiteralKeyOnAMessage(_ call: SubscriptCallExprSyntax) -> Bool {
        guard call.arguments.count == 1, let argument = call.arguments.first, argument.label == nil,
              let literal = argument.expression.as(StringLiteralExprSyntax.self),
              !forecastSeries.contains(text(of: literal) ?? "")
        else { return false }
        let base = call.calledExpression.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
        return messageNames.contains { base.range(of: $0, options: .caseInsensitive) != nil }
    }

    private static func text(of literal: StringLiteralExprSyntax) -> String? {
        guard literal.segments.count == 1, case let .stringSegment(segment)? = literal.segments.first else { return nil }
        return segment.content.text
    }

    private static let rule = Rule(
        description: "Watch messages are keyed with WatchMessageKeys on the phone and the watch, never with string literals.",
        rationale: """
        WatchMessageKeys is a member of both targets, so a key named there is one name on both sides. A literal is typed
        twice: renamed or mistyped on one side, the other side's `message[key] as? T` is nil and the message is dropped
        with no error. "watchLogs" existed only as literals, and the keys inside a glucose value or a preset entry are the
        same contract one level down.
        """,
        fixHint: "Add the key to WatchMessageKeys (Trio/Sources/Models/WatchMessageKeys.swift) and use it where the message is built and where it is read.",
        badExample: "let payload: [String: Any] = [\"watchLogs\": logs]   //   message[\"watchLogs\"] as? String",
        goodExample: "let payload: [String: Any] = [WatchMessageKeys.watchLogs: logs]   //   message[WatchMessageKeys.watchLogs] as? String"
    )
}
