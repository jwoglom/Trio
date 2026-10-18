import Foundation

/// The objects of a project.pbxproj by id, read as text: enough to say which Swift files a target compiles.
struct XcodeProject {
    private let objects: [String: String]
    private let parents: [String: String]

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

        var parents: [String: String] = [:]
        for (id, group) in objects where group.contains("isa = PBXGroup;") || group.contains("isa = PBXVariantGroup;") {
            for child in Self.ids(in: "children", of: group) {
                parents[child] = id
            }
        }
        self.parents = parents
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

    /// Every Swift file some native target compiles, as a path relative to the project root.
    var swiftFilePathsCompiledByAnyTarget: Set<String> {
        let phases = objects.values.filter { $0.contains("isa = PBXNativeTarget;") }
            .flatMap { Self.ids(in: "buildPhases", of: $0) }
            .compactMap { objects[$0] }
            .filter { $0.contains("isa = PBXSourcesBuildPhase;") }

        let paths = phases.flatMap { Self.ids(in: "files", of: $0) }.compactMap { buildFile -> String? in
            guard let buildFile = objects[buildFile],
                  let reference = Self.value(of: "fileRef", in: buildFile)?.prefix(24)
            else { return nil }
            return path(of: String(reference))
        }
        return Set(paths.filter { $0.hasSuffix(".swift") })
    }

    /// The folders whose files Xcode compiles without listing them one by one.
    var synchronizedGroupFolders: [String] {
        objects.filter { $0.value.contains("isa = PBXFileSystemSynchronizedRootGroup;") }.keys.compactMap(path(of:)).sorted()
    }

    /// A file reference's or group's path relative to the project root: its own `path` under its ancestors'.
    private func path(of id: String) -> String? {
        var parts: [String] = []
        var current: String? = id
        while let id = current, let object = objects[id] {
            if let path = Self.value(of: "path", in: object) {
                parts.append(path)
            }
            if Self.value(of: "sourceTree", in: object) == "SOURCE_ROOT" { break }
            current = parents[id]
        }
        return parts.isEmpty ? nil : parts.reversed().joined(separator: "/")
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

    /// The text of `field = value;`, unquoted; the field follows a space in a one-line object and a tab in a multi-line one.
    private static func value(of field: String, in object: String) -> String? {
        guard let start = object.range(of: " \(field) = ") ?? object.range(of: "\t\(field) = "),
              let end = object.range(of: ";", range: start.upperBound ..< object.endIndex)
        else { return nil }
        let value = object[start.upperBound ..< end.lowerBound]
        return value.hasPrefix("\"") ? String(value.dropFirst().dropLast()) : String(value)
    }
}
