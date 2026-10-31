import Combine
import Foundation
import Swinject
import UIKit

/// Saves a full 24-hour log export to Documents/SavedLogs once a day, just after midnight, while
/// Auto-save Logs is on under Report a Problem > Advanced Options.
///
/// iOS cannot wake an app at a set time, so the check runs whenever a loop finishes and whenever
/// Trio comes to the foreground. Loops keep running in the background, so the file normally lands
/// within minutes of 12:01 am; if Trio was not running then, it is saved at the next chance.
final class LogAutoSave: Injectable {
    @Injected() private var apsManager: APSManager!
    @Injected() private var logExport: LogExport!

    static let folderName = "SavedLogs"

    // A failed export is retried later rather than on every loop
    private static let retryInterval: TimeInterval = 60 * 60

    private var subscriptions = Set<AnyCancellable>()
    @MainActor private var isSaving = false
    @MainActor private var retryAfter: Date?

    init(resolver: Resolver) {
        injectServices(resolver)
        // The current value at launch is skipped; Core Data may still be loading
        apsManager.isLooping
            .dropFirst()
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.check() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.check() }
            .store(in: &subscriptions)
    }

    static var isEnabled: Bool {
        PropertyPersistentFlags.shared.autoSaveLogsEnabled == true
    }

    /// Turning it on counts the latest 12:01 am as done, so the first file is saved at the next one.
    static func setEnabled(_ enabled: Bool, now: Date = Date()) {
        PropertyPersistentFlags.shared.autoSaveLogsEnabled = enabled
        if enabled {
            PropertyPersistentFlags.shared.autoSaveLogsLastSlot = latestSlot(atOrBefore: now)
        }
        info(.storage, "Auto-save logs \(enabled ? "enabled" : "disabled")")
    }

    /// The most recent 12:01 am at or before `date`. Built from the start of the day, which
    /// stays valid on days a time zone skips midnight for daylight saving.
    static func latestSlot(atOrBefore date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-60)).addingTimeInterval(60)
    }

    static func isDue(now: Date, lastSlot: Date?, calendar: Calendar = .current) -> Bool {
        guard let lastSlot else { return true }
        return lastSlot < latestSlot(atOrBefore: now, calendar: calendar)
    }

    /// Named after the day that ended at the slot's midnight, which the 24 hours of logs cover.
    static func fileName(forSlot slot: Date, calendar: Calendar = .current) -> String {
        let coveredDay = calendar.startOfDay(for: slot).addingTimeInterval(-1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: coveredDay)).zip"
    }

    static func folderURL() throws -> URL {
        try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private func check() {
        Task { @MainActor in await saveIfDue() }
    }

    @MainActor private func saveIfDue() async {
        let now = Date()
        guard Self.isEnabled, !isSaving, let logExport else { return }
        if let retryAfter, now < retryAfter { return }
        guard Self.isDue(now: now, lastSlot: PropertyPersistentFlags.shared.autoSaveLogsLastSlot) else { return }

        isSaving = true
        defer { isSaving = false }
        do {
            // Same file as Share Trio Logs > All Logs > Last 24 Hours
            let file = try await logExport.makeFile(.all, days: 1)
            defer { LogExport.discard(file) }
            let slot = Self.latestSlot(atOrBefore: now)
            let name = Self.fileName(forSlot: slot)
            try Self.store(file, as: name)
            PropertyPersistentFlags.shared.autoSaveLogsLastSlot = slot
            retryAfter = nil
            info(.storage, "Auto-saved logs to \(Self.folderName)/\(name)")
        } catch {
            retryAfter = now.addingTimeInterval(Self.retryInterval)
            warning(.storage, "Auto-saving logs failed", error: error)
        }
    }

    private static func store(_ file: URL, as name: String) throws {
        let folder = try folderURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        // A time zone change can bring the same date round twice; keep the newer file
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}
