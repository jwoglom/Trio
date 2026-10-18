import Foundation
import Harmonize
import HarmonizeSemantics
import SwiftParser
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

/// A syntax node inside a file, reported by Harmonize's assertions at its own line rather than the file's.
private struct Occurrence<Node: SyntaxProtocol>: SyntaxNodeProviding, SourceCodeProviding, NamedDeclaration,
    CustomStringConvertible
{
    let node: Node
    let name: String
    let sourceCodeLocation: SourceCodeLocation

    var description: String { name }
}

private extension SwiftSourceCode {
    /// Every `Node` in the file, skipping preview code, which never reaches a user.
    func occurrences<Node: SyntaxProtocol>(of _: Node.Type, name: (Node) -> String) -> [Occurrence<Node>] {
        let tree = Parser.parse(source: source)
        let location = SourceCodeLocation(sourceFilePath: filePath, sourceFileTree: tree)
        let collector = NodeCollector<Node>()
        collector.walk(tree)
        return collector.nodes.map { Occurrence(node: $0, name: name($0), sourceCodeLocation: location) }
    }
}

private final class NodeCollector<Node: SyntaxProtocol>: SyntaxAnyVisitor {
    var nodes: [Node] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if node.isPreviewCode { return .skipChildren }
        if let match = node.as(Node.self) { nodes.append(match) }
        return .visitChildren
    }
}

private extension SyntaxProtocol {
    var isPreviewCode: Bool {
        if let macro = self.as(MacroExpansionExprSyntax.self) { return macro.macroName.text == "Preview" }
        if let macro = self.as(MacroExpansionDeclSyntax.self) { return macro.macroName.text == "Preview" }
        if let type = self.as(StructDeclSyntax.self) {
            return type.name.text.hasPrefix("Preview")
                || type.inheritanceClause?.inheritedTypes.contains { $0.type.trimmedDescription == "PreviewProvider" } == true
        }
        if let type = self.as(ClassDeclSyntax.self) { return type.name.text.hasPrefix("Preview") }
        if let function = self.as(FunctionDeclSyntax.self) { return function.name.text.lowercased().hasPrefix("preview") }
        if let variable = self.as(VariableDeclSyntax.self) {
            return variable.bindings.contains {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text.lowercased().hasPrefix("preview") == true
            }
        }
        return false
    }
}
