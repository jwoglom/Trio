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

/// The objects of a project.pbxproj by id, read as text: enough to say which Swift files a target compiles.
private struct XcodeProject {
    private let objects: [String: String]

    init(contentsOf url: URL) {
        var objects: [String: String] = [:]
        var open: (id: String, lines: [Substring])?
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let object = open {
                if line == "\t\t};" {
                    objects[object.id] = object.lines.joined(separator: "\n")
                    open = nil
                } else {
                    open?.lines.append(line)
                }
            } else if let id = Self.objectID(opening: line) {
                if line.hasSuffix("};") {
                    objects[id] = String(line)
                } else {
                    open = (id, [line])
                }
            }
        }
        self.objects = objects
    }

    func swiftFileNames(compiledBy target: String) -> Set<String> {
        guard let target = objects.values.first(where: { $0.contains("isa = PBXNativeTarget;") && Self.isNamed($0, target) }),
              let phase = Self.ids(in: "buildPhases", of: target).compactMap({ objects[$0] })
              .first(where: { $0.contains("isa = PBXSourcesBuildPhase;") })
        else { return [] }

        let names = Self.ids(in: "files", of: phase).compactMap { buildFile -> String? in
            guard let buildFile = objects[buildFile],
                  let reference = Self.value(of: "fileRef", in: buildFile)?.prefix(24),
                  let path = objects[String(reference)].flatMap({ Self.value(of: "path", in: $0) })
            else { return nil }
            return (path as NSString).lastPathComponent
        }
        return Set(names.filter { $0.hasSuffix(".swift") })
    }

    private static func objectID(opening line: Substring) -> String? {
        guard line.hasPrefix("\t\t"), !line.hasPrefix("\t\t\t") else { return nil }
        let id = line.dropFirst(2).prefix(24)
        guard id.count == 24, id.allSatisfy(\.isHexDigit), line.dropFirst(26).hasPrefix(" /*") else { return nil }
        return String(id)
    }

    private static func isNamed(_ object: String, _ name: String) -> Bool {
        object.contains("\tname = \(name);") || object.contains("\tname = \"\(name)\";")
    }

    /// The ids listed in `field = ( ... );`.
    private static func ids(in field: String, of object: String) -> [String] {
        guard let start = object.range(of: "\(field) = ("),
              let end = object.range(of: ");", range: start.upperBound ..< object.endIndex)
        else { return [] }
        return object[start.upperBound ..< end.lowerBound]
            .split { !$0.isHexDigit }
            .filter { $0.count == 24 }
            .map(String.init)
    }

    /// The text of `field = value;`, unquoted.
    private static func value(of field: String, in object: String) -> String? {
        guard let start = object.range(of: " \(field) = "),
              let end = object.range(of: ";", range: start.upperBound ..< object.endIndex)
        else { return nil }
        let value = object[start.upperBound ..< end.lowerBound]
        return value.hasPrefix("\"") ? String(value.dropFirst().dropLast()) : String(value)
    }
}
