import Foundation
import Harmonize
import Testing

@Suite struct SourceFilesAreMembersOfATarget {
    @Test func everySourceFileIsCompiledBySomeTarget() {
        let compiled = Self.project.swiftFilePathsCompiledByAnyTarget
        let folders = Self.project.synchronizedGroupFolders + [Self.algorithmPackageDirectory]

        TrioHarmonize.productionCode.sources().assertTrue(rule: Self.rule, strict: true) { file in
            compiled.contains(file.relativePath) || folders.contains { file.relativePath.hasPrefix($0 + "/") }
        }
    }

    // The allowance for that directory holds only while the package compiles it wholesale.
    @Test func theAlgorithmPackageCompilesItsDirectoryWholesale() {
        let manifest = TrioHarmonize.projectRoot.appendingPathComponent("AlgorithmPackage/Package.swift")
        let contents = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""

        #expect(
            contents.contains("\"APS/OpenAPSSwift\""),
            "AlgorithmPackage no longer compiles \(Self.algorithmPackageDirectory) as a directory; list its files in the rule instead"
        )
    }

    private static let algorithmPackageDirectory = "Trio/Sources/APS/OpenAPSSwift"

    private static let project = XcodeProject(
        contentsOf: TrioHarmonize.projectRoot.appendingPathComponent("Trio.xcodeproj/project.pbxproj")
    )

    private static let rule = Rule(
        description: "Every Swift file in Trio's source folders is compiled by a target of Trio.xcodeproj, or lies in a folder compiled wholesale.",
        rationale: """
        The project lists source files one by one, so a file it does not list is dead code that still gets edited,
        with no compile error to say so. The AddCarbs and AutotuneConfig modules outlived their Screen cases by
        releases; a stale ContactImageEntryStored class pair sat beside the class Core Data now generates, and
        would have broken the build had anyone "fixed" its membership; and every orphan kept the old patterns a
        grep for them trips over. A file under a synchronized group (LiveActivity/Views, the watch extension's
        Preview Content) is a member without being listed, and AlgorithmPackage compiles Trio/Sources/APS/OpenAPSSwift
        wholesale, which is how AlgorithmLoggingShim.swift stands in for the app's logger from no Xcode target.
        """,
        fixHint: "Add the file to its target in Xcode, or delete it. A file nothing compiles is removed, not kept for reference.",
        badExample: "// Trio/Sources/Helpers/SettingsRowView.swift on disk, and no SettingsRowView.swift in any Sources phase",
        goodExample: "38F37828261260DC009DB701 /* Color+Extensions.swift in Sources */, // in the Trio target's Sources phase"
    )
}
