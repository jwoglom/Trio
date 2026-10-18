import Foundation
import Harmonize
import HarmonizeSemantics
import SwiftSyntax
import Testing

@Suite struct LoggingGoesThroughTheLogger {
    @Test func appCodeDoesNotLogToTheConsoleOrToOSLogDirectly() {
        let calls = TrioHarmonize.app.excluding("Logger").sources().flatMap { file in
            file.occurrences(of: FunctionCallExprSyntax.self) { "\($0.calledExpression.trimmedDescription)(" }
                .filter { Self.isDirectLogging($0.node) }
        }

        calls.assertEmpty(rule: Self.rule)
    }

    private static let consoleCalls: Set<String> = [
        "print", "Swift.print", "debugPrint", "Swift.debugPrint", "NSLog", "os_log", "os.os_log", "OSLog", "os.OSLog"
    ]

    private static func isDirectLogging(_ call: FunctionCallExprSyntax) -> Bool {
        let callee = call.calledExpression.trimmedDescription
        if consoleCalls.contains(callee) { return true }
        // os.Logger(subsystem:category:); Trio's own Logger is built from a category and a reporter.
        return ["Logger", "os.Logger"].contains(callee) && call.arguments.first?.label?.text == "subsystem"
    }

    private static let rule = Rule(
        description: "App code logs through debug/info/warning(.category, ...), never print, debugPrint, NSLog or os_log.",
        rationale: """
        The Logger's free functions write to os_log and to Documents/logs/log.txt, the file a user attaches to a
        support request. print and debugPrint reach the Xcode console alone, and os_log under an ad hoc subsystem
        reaches Console.app alone, so a failure logged that way, such as a critical alert whose audio did not start,
        leaves no trace in the field.
        """,
        fixHint: "Call debug(.category, message), or info/warning, with the Logger.Category for the area; pass a non-String as \"\\(value)\".",
        badExample: "debugPrint(\"\\(DebuggingIdentifiers.failed) Failed to save glucose: \\(error)\")",
        goodExample: "debug(.coreData, \"\\(DebuggingIdentifiers.failed) Failed to save glucose: \\(error)\")"
    )
}
