import CoreData
import Foundation
import SwiftUI
import Swinject

extension DatabaseExport {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var fileManager: FileManager!

        @Published var isExporting: Bool = false

        override func subscribe() {}

        enum ExportError: LocalizedError {
            case documentsDirectoryNotFound
            case persistentStoreNotFound
            case exportFailed(Error)

            var errorDescription: String? {
                switch self {
                case .documentsDirectoryNotFound:
                    return String(localized: "Could not access documents directory")
                case .persistentStoreNotFound:
                    return String(localized: "Could not locate the Trio database on disk")
                case let .exportFailed(error):
                    return String(localized: "Database export failed: \(error.localizedDescription)")
                }
            }
        }

        /// Exports the entire Trio database into a single ZIP archive.
        ///
        /// The archive contains:
        /// - The main CoreData SQLite store, consolidated into a single portable `.sqlite` file
        /// - The JSON configuration files stored in the app's Documents directory
        ///
        /// Keychain credentials are intentionally excluded. The CoreData store is copied via a
        /// throwaway read-only coordinator, so the app's live store is never modified.
        ///
        /// - Returns: A Result containing either the ZIP file URL on success or an ExportError on failure.
        func exportDatabase() async -> Result<URL, ExportError> {
            debug(.default, "🔄 DB EXPORT: Starting database export...")

            await MainActor.run { isExporting = true }
            defer { Task { @MainActor in isExporting = false } }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())

            guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return .failure(.documentsDirectoryNotFound)
            }

            let stagingDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("TrioDatabase_\(timestamp)", isDirectory: true)

            do {
                try? fileManager.removeItem(at: stagingDirectory)
                try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

                try exportCoreDataStore(to: stagingDirectory)
                try copyJSONConfigs(from: documentsDirectory, to: stagingDirectory)

                let zipURL = try zip(
                    directory: stagingDirectory,
                    to: documentsDirectory,
                    named: "TrioDatabase_\(timestamp).zip"
                )

                try? fileManager.removeItem(at: stagingDirectory)
                debug(.default, "🔄 DB EXPORT: Finished export at \(zipURL.path)")
                return .success(zipURL)
            } catch let error as ExportError {
                try? fileManager.removeItem(at: stagingDirectory)
                return .failure(error)
            } catch {
                try? fileManager.removeItem(at: stagingDirectory)
                return .failure(.exportFailed(error))
            }
        }

        /// Copies the live CoreData SQLite store into `directory` as a single consolidated file.
        ///
        /// Uses a throwaway, read-only `NSPersistentStoreCoordinator` and `migratePersistentStore`
        /// with `journal_mode = DELETE`, which merges the WAL into one portable `.sqlite` file
        /// without detaching or mutating `CoreDataStack.shared`'s live store.
        private func exportCoreDataStore(to directory: URL) throws {
            let coordinator = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
            guard let sourceURL = coordinator.persistentStores.first?.url else {
                throw ExportError.persistentStoreNotFound
            }

            let backupCoordinator = NSPersistentStoreCoordinator(
                managedObjectModel: CoreDataStack.managedObjectModel
            )
            let sourceStore = try backupCoordinator.addPersistentStore(
                type: .sqlite,
                at: sourceURL,
                options: [NSReadOnlyPersistentStoreOption: true]
            )

            let destinationURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
            _ = try backupCoordinator.migratePersistentStore(
                sourceStore,
                to: destinationURL,
                options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]],
                type: .sqlite
            )
        }

        /// Copies every top-level `*.json` file from the Documents directory into `staging/config/`.
        ///
        /// Only regular JSON files at the Documents root are copied; the `logs/` subdirectory and
        /// any prior export artifacts (`.zip`, `.csv`) are skipped since they are not JSON files.
        private func copyJSONConfigs(from documentsDirectory: URL, to stagingDirectory: URL) throws {
            let configDirectory = stagingDirectory.appendingPathComponent("config", isDirectory: true)
            try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)

            let contents = try fileManager.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            for fileURL in contents where fileURL.pathExtension.lowercased() == "json" {
                let destination = configDirectory.appendingPathComponent(fileURL.lastPathComponent)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: fileURL, to: destination)
            }
        }

        /// Zips `directory` into `destinationDirectory/fileName` using `NSFileCoordinator`'s native
        /// `.forUploading` option (no third-party dependency). The coordinator hands back a temporary
        /// zip that only lives for the duration of the accessor block, so it is moved out immediately.
        private func zip(directory: URL, to destinationDirectory: URL, named fileName: String) throws -> URL {
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            var thrownError: Error?
            let destinationURL = destinationDirectory.appendingPathComponent(fileName)

            coordinator.coordinate(
                readingItemAt: directory,
                options: [.forUploading],
                error: &coordinatorError
            ) { zippedURL in
                do {
                    try? fileManager.removeItem(at: destinationURL)
                    try fileManager.moveItem(at: zippedURL, to: destinationURL)
                } catch {
                    thrownError = error
                }
            }

            if let coordinatorError { throw coordinatorError }
            if let thrownError { throw thrownError }
            return destinationURL
        }
    }
}
