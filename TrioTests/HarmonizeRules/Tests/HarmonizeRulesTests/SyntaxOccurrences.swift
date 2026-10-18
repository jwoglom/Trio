import Foundation
import Harmonize
import HarmonizeSemantics
import SwiftParser
import SwiftSyntax

/// A syntax node inside a file, reported by Harmonize's assertions at its own line rather than the file's.
struct Occurrence<Node: SyntaxProtocol>: SyntaxNodeProviding, SourceCodeProviding, NamedDeclaration,
    CustomStringConvertible
{
    let node: Node
    let name: String
    let sourceCodeLocation: SourceCodeLocation

    var description: String { name }

    /// The same occurrence with its node type erased, so occurrences of different node types go in one assertion.
    var erased: Occurrence<SwiftSyntax.Syntax> {
        Occurrence<SwiftSyntax.Syntax>(node: SwiftSyntax.Syntax(node), name: name, sourceCodeLocation: sourceCodeLocation)
    }
}

extension SwiftSourceCode {
    /// Every `Node` in the file, skipping preview code, which never reaches a user.
    func occurrences<Node: SyntaxProtocol>(of _: Node.Type, name: (Node) -> String) -> [Occurrence<Node>] {
        let tree = Parser.parse(source: source)
        let location = SourceCodeLocation(sourceFilePath: filePath, sourceFileTree: tree)
        let collector = NodeCollector<Node>()
        collector.walk(tree)
        return collector.nodes.map { Occurrence(node: $0, name: name($0), sourceCodeLocation: location) }
    }
}

final class NodeCollector<Node: SyntaxProtocol>: SyntaxAnyVisitor {
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

extension SyntaxProtocol {
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
