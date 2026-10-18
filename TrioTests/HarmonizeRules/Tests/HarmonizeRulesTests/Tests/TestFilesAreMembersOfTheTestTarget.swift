import Foundation
import Harmonize
import Testing

@Suite struct TestFilesAreMembersOfTheTestTarget {
    @Test func unitTestFilesAreInTheTrioTestsTarget() {
        let members = Self.project.swiftFileNames(compiledBy: "TrioTests")

        TrioHarmonize.unitTests.sources().assertTrue(rule: Self.rule, strict: true) { members.contains($0.fileName ?? "") }
    }

    @Test func watchTestFilesAreInTheWatchTestsTarget() {
        let members = Self.project.swiftFileNames(compiledBy: "Trio Watch AppTests")

        TrioHarmonize.watchTests.sources().assertTrue(rule: Self.rule, strict: true) { members.contains($0.fileName ?? "") }
    }

    // Membership is matched by file name, so two test files sharing one would let an orphan hide behind its namesake.
    @Test func testFileNamesAreUnique() {
        let names = (TrioHarmonize.unitTests.sources() + TrioHarmonize.watchTests.sources()).compactMap(\.fileName)
        let duplicates = Dictionary(grouping: names) { $0 }.filter { $0.value.count > 1 }.keys.sorted()

        #expect(duplicates.isEmpty, "Rename one of each pair:\n\(duplicates.joined(separator: "\n"))")
    }

    private static let project = XcodeProject(
        contentsOf: TrioHarmonize.projectRoot.appendingPathComponent("Trio.xcodeproj/project.pbxproj")
    )

    private static let rule = Rule(
        description: "Every Swift file under TrioTests and Trio Watch App Tests is a member of its test target.",
        rationale: """
        The project lists test files one by one, so a file that is not listed compiles for nobody and never runs.
        SettingsExportTests sat in TrioTests through many releases against an API that had moved to another module
        in the meantime, and no CI run ever noticed.
        """,
        fixHint: """
        Add the file to the TrioTests (or Trio Watch AppTests) target in Xcode, or delete it. A test that no longer
        compiles is fixed or removed, never left out of the target.
        """,
        badExample: "// TrioTests/SettingsExportTests.swift on disk, and no SettingsExportTests.swift in Trio.xcodeproj",
        goodExample: "BD11A001000000000000A016 /* SettingsExportTests.swift in Sources */, // in the TrioTests Sources phase"
    )
}
