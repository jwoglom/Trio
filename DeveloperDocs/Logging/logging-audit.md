# Logging in Trio vs. Loop/LoopKit: audit and refactor proposal

*Contributor-facing. Snapshot taken against Trio `dev` (0.8.4.97), Loop `dev`, and LoopKit `dev` on 2026-09-12. Line numbers are approximate and will drift.*

## 1. Summary

Trio and Loop both sit on LoopKit, and LoopKit ships a complete device-communication logging pipeline: a `DeviceManagerDelegate` callback, a Core Data backed `PersistentDeviceLog`, a `CriticalEventLog` export protocol, and a `LoggingService` plugin hook. Loop uses all of it. Trio uses none of it.

Trio's current logging is a single global text file (`Documents/logs/log.txt`) written synchronously under a global lock, rotated once a day, with no levels, no retention beyond "yesterday," and no structured metadata. The LoopKit device-log delegate is implemented in two places, but both flatten the call into a plain `debug(...)` string and throw away the manager identifier, device identifier, and entry type. Five device kits in Trio's submodule set have grown their own copies of the same file-logger pattern, writing to five separate folders that Trio's "Share Logs" button never includes. Watch logs land in a third file that is also not shared.

Loop's model is: everything worth keeping goes to Core Data with a retention window, and a report is assembled on demand from live state plus recent store contents. It produces two artifacts: a human-readable "Loop Report" markdown file, and a "Critical Event Log" zip of per-store JSON. That model is the right shape for Trio. Loop's implementation of it has real weaknesses (Section 3.6), and the proposal in Section 5 keeps the shape while fixing them.

Headline recommendations:

1. Stop flattening the LoopKit device log. Instantiate `PersistentDeviceLog` and forward the delegate call faithfully. This is a small change with the highest value per line.
2. Replace `SimpleLogReporter` with an asynchronous, batched, Core Data backed app log with levels and a retention window.
3. Replace "Share Logs" with a generated diagnostic report that includes device `debugDescription`s (which every kit already provides and Trio never reads), the device comm log, the app log, alert history, and the oref state files.
4. Add a `CriticalEventLog`-style structured export as a second phase, reusing LoopKit's protocol and Loop's exporter.
5. Set a logging policy for kits and push it upstream to the `loopandlearn` forks: device I/O goes through `logDeviceCommunication`, internals go through `os.Logger`, and no kit writes its own files.

## 2. How Loop and LoopKit log today

Loop has four distinct layers. They are loosely coupled and were added at different times, which is part of why the result feels inconsistent.

### 2.1 Layer A: unified log plus optional plugin fan-out

- `LoopKit/Extensions/OSLog.swift` adds `debug/info/default/error` conveniences on `OSLog` with subsystem `com.loopkit.LoopKit`. LoopKit's own stores use this.
- `Loop/Extensions/DiagnosticLog.swift` is Loop's app-side equivalent (subsystem `com.loopkit.Loop`). It writes to `os_log` and then forwards to `SharedLogging.instance` if set.
- `SharedLogging.instance` is set to a `LoggingServicesManager` in `LoopAppManager`. That manager fans each message out to every active `Service` that conforms to `LoggingService` (`LoopKit/Service/LoggingService.swift`). `ServicesManager` adds and removes services from it as plugins are enabled.

Nothing in this layer is persisted by Loop itself. If no logging-capable service is installed, these messages exist only in the unified log and are gone after the process dies. Loop has 18 `DiagnosticLog` call sites and 19 `OSLog` sites in the app target, so this layer is thin by design.

### 2.2 Layer B: device communication log in Core Data

- `LoopKit/DeviceManager/DeviceManager.swift` declares `DeviceManagerDelegate.deviceManager(_:logEventForDeviceIdentifier:type:message:completion:)`. Both `PumpManagerDelegate` and `CGMManagerDelegate` inherit it.
- `DeviceLogEntryType` is `send`, `receive`, `error`, `delegate`, `delegateResponse`, `connection`.
- `PersistentDeviceLog` (`LoopKit/DeviceManager/DeviceLog/`) owns its own `NSPersistentContainer` with the `DeviceLog` model, a private-queue context, and one entity `Entry` with `timestamp`, `managerIdentifier`, `deviceIdentifier`, `type`, `message`, `modificationCounter`. Default `maxEntryAge` is 7 days. Expired rows are purged lazily on `getLogEntries` and after each export.
- Loop creates it in `DeviceDataManager.init` at `Documents/DeviceLog/Storage.sqlite` with `maxEntryAge` equal to `localCacheDuration` (from `LOOP_LOCAL_CACHE_DURATION_DAYS`). The delegate implementation is one line that calls `deviceLog.log(managerIdentifier: manager.pluginIdentifier, ...)`.
- Every mainstream kit defines a private `logDeviceCommunication(_:type:)` helper that calls the delegate. LoopKit itself does not provide this helper; each kit copies it.

### 2.3 Layer C: the "Issue Report" markdown

`SettingsView` → `SettingsViewModel.didTapIssueReport` → `CommandResponseViewController.generateDiagnosticReport(deviceManager:)` → `DeviceDataManager.generateDiagnosticReport`. Output is a file named `Loop Report <ISO date>.md` offered through a share sheet.

Contents in order:

- Build details (version, profile expiration, source root, Xcode version, workspace branch and SHA, each submodule's branch and SHA).
- `FeatureFlags`.
- Alerts issued in the last 84 hours, capped at 100 rows.
- `DeviceDataManager` state (`launchDate`, `lastError`).
- `String(reflecting:)` of the `cacheStore`, the CGM manager, and the pump manager. `DeviceManager` requires `CustomDebugStringConvertible`, so every kit already supplies a rich state dump for free.
- Device communication log for the last 84 hours.
- Watch manager and status extension state.
- `LoopDataManager` report: settings, effect arrays, predicted glucose, retrospective correction, then each store's `generateDiagnosticReport` (glucose samples for 24 hours, carb entries, dose store, insulin delivery store), meal detection, pending notifications, and `UIDevice` info.

The assembly is a five-deep pyramid of completion handlers building `[String]` arrays and joining them.

### 2.4 Layer D: Critical Event Log export

- `LoopKit/CriticalEventLog.swift` defines a protocol with `exportName`, `exportProgressTotalUnitCount`, and `export(startDate:endDate:to:progress:)` that streams JSON through `JSONStreamEncoder` onto a `DataOutputStream`.
- Implemented by `SettingsStore`, `GlucoseStore`, `CarbStore`, `DosingDecisionStore`, `DoseStore`, `PersistentDeviceLog` (all LoopKit), and `AlertStore` (Loop).
- `Loop/Managers/CriticalEventLogExportManager.swift` writes one zip per UTC day into a directory, purges archives older than `historicalDuration`, and runs as a `BGProcessingTask` scheduled from `LoopAppManager`. A "full export" bundles the daily archives plus a fresh "today" archive into one zip on demand, with progress UI (`CriticalEventLogExportView`). Zipping uses `Loop/Models/ZipArchive.swift` on top of `ZIPFoundation`.

### 2.5 Where Loop's data lives

| Data | Store | Retention |
|---|---|---|
| Device comm log | `Documents/DeviceLog/Storage.sqlite` (own container) | `localCacheDuration`, purged lazily |
| Alerts | `AlertStore` Core Data | `expireAfter: localCacheDuration` |
| Glucose, carbs, doses, dosing decisions, settings | LoopKit stores, shared `PersistenceController` | `localCacheDuration` |
| App-level `DiagnosticLog` messages | unified log only, plus any `LoggingService` | OS-controlled |
| Critical event archives | `Documents/CriticalEventLogs/*.zip` | `historicalDuration` |

## 3. How Trio logs today

### 3.1 The app-level logger

`Trio/Sources/Logger/Logger.swift` exposes four global free functions: `debug(_ category:, _ message:)`, `info`, `warning`, and `error`. There are 13 categories. Each `Logger.Category` maps to an `OSLog(subsystem: bundleIdentifier, category:)`, except `.default`, which maps to `OSLog.default` and therefore has no subsystem or category in Console.

Every call does two things, in order, on the calling thread:

1. `os_log` with the level implied by the function (`debug` → `.debug`, `info` → `.info`, `warning` → `.default`, `error` → `.error`). The format string is `"%@ - %@ - %d %{public}@"`, so file and function are private-redacted in Console but the message is public.
2. `reporter.log(category, message, ...)` on a `GroupedIssueReporter` resolved from Swinject. The only registered reporter is `SimpleLogReporter` (`Assemblies/ServiceAssembly.swift`).

Observations:

- The `DispatchWorkItem(qos: .background, flags: .enforceQoS) { ... }.perform()` wrapper does not dispatch anywhere. `perform()` runs the block synchronously on the caller. The `qos` argument has no effect. Every log call blocks the caller for the duration of the file write.
- All calls serialize on one global `NSRecursiveLock` (`loggerLock`). The lock is held across the `os_log` call and the file write.
- `error(...)` returns `Never` and calls `fatalError`. It is used exactly once. It means nothing in the codebase can log at error level without crashing, which explains why 93 percent of call sites are `debug`.
- `warning` calls `reporter.reportNonFatalIssue(withError:)`. `SimpleLogReporter` implements that as a no-op. Nothing consumes it.
- `info` is used once in the whole app. `check(...)` is defined but the level semantics collapse to `warning`.
- `Signpost.swift` exists but `Config.withSignPosts` is `false` and there are zero call sites.

Call-site distribution in the app target (588 total):

| Category | debug | warning | info | error |
|---|---|---|---|---|
| default | 142 | 1 | | |
| watchManager | 74 | | | |
| deviceManager | 70 | 4 | | |
| service | 64 | 14 | 1 | 1 |
| nightscout | 61 | 4 | | |
| apsManager | 34 | 3 | | |
| storage | 25 | | | |
| remoteControl | 22 | | | |
| telemetry | 19 | | | |
| bolusState | 15 | | | |
| coreData | 12 | | | |
| openAPS | 9 | 4 | | |
| businessLogic | 9 | | | |

There are also 25 bare `print(` sites in the app target and 8 in `LoopAlgorithm`.

### 3.2 The file sink

`SimpleLogReporter` appends one line per call to `Documents/logs/log.txt`:

```
yyyy-MM-dd'T'HH:mm:ssZ [Category] File.swift - function() - line - DEV: message
```

- The level is only recoverable from the `DEV:` / `INFO:` / `WARN:` / `ERR:` prefix baked into the message.
- Timestamps have one-second resolution. A loop cycle emits dozens of lines within the same second and their order within it is the only clue.
- Rotation checks the file's creation date on every write and moves `log.txt` to `log_prev.txt` once per calendar day. Total retention is therefore between 24 and 48 hours. There is no size cap.
- Each write opens a file descriptor, writes, and closes it (`Data.append(fileURL:)` via `FileDescriptor.open`). Combined with the global lock this is the app's single hottest synchronous I/O path.
- A new `DateFormatter` is constructed on every call (`dateFormatter` is a computed property).

### 3.3 The share path

`SettingsStateModel.logItems()` returns `log.txt` and `log_prev.txt` if they exist. `SettingsRootView` presents them under "Share Logs" via a share sheet. Nothing else is included: no build information header, no settings snapshot, no device state, no watch log, no kit logs, no alert history.

### 3.4 Device logging: the LoopKit hook is implemented, then discarded

Two delegate implementations exist:

```swift
// Trio/Sources/APS/DeviceDataManager.swift
func deviceManager(_: DeviceManager, logEventForDeviceIdentifier _: String?,
                   type _: DeviceLogEntryType, message: String, completion _: ((Error?) -> Void)?) {
    debug(.deviceManager, "Device message: \(message)")
}

// Trio/Sources/APS/CGM/PluginSource.swift
func deviceManager(_: LoopKit.DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?,
                   type _: LoopKit.DeviceLogEntryType, message: String, completion _: ((Error?) -> Void)?) {
    debug(.deviceManager, "device Manager for \(String(describing: deviceIdentifier)) : \(message)")
}
```

The pump path drops the manager identifier, the device identifier, and the type. The CGM path drops the manager identifier and the type. The completion handler is never called, so any kit waiting on it (none currently do, but the protocol allows it) would hang. `PersistentDeviceLog` is never instantiated anywhere in Trio.

Trio's LoopKit fork (`loopandlearn/LoopKit`, branch `trio`) is byte-identical to upstream in `PersistentDeviceLog.swift`, `DeviceLogEntryType.swift`, `DeviceManager.swift`, `LoggingService.swift`, `CriticalEventLog.swift`, and `Extensions/OSLog.swift`. The `DeviceLog.xcdatamodeld` ships inside the LoopKit framework bundle. Everything needed is already linked into Trio.

Trio never reads `debugDescription` from its pump or CGM manager. `String(reflecting:)` appears once in the app target, in `Router/Screen.swift`, unrelated to logging.

### 3.5 Device kits: five logging dialects

Counts exclude test targets. "deviceLog" counts calls to `logDeviceCommunication` or the delegate directly. "own file" means the kit writes its own log file under `Documents`.

| Kit | deviceLog | os_log / os.Logger | print | Own file |
|---|---|---|---|---|
| OmnipodKit | 19 | 437 | 50 | no |
| DanaKit | 51 | 215 | 0 | `danakit/dana_log.txt` |
| LibreTransmitter | 8 | 207 | 57 | no |
| EversenseKit | 1 | 206 | 1 | `eversense/eversense_log.txt` |
| MedtrumKit | 3 | 146 | 0 | `medtrumkit/medtrumkit_log.txt` |
| AccuChekKit | 0 | 118 | 5 | `accuchek/accuchek_log.txt` |
| RileyLinkKit | 1 | 76 | 6 | no |
| G7SensorKit | 15 | 73 | 0 | no |
| CGMBLEKit | 10 | 65 | 1 | no |
| MinimedKit | 7 | 43 | 12 | no |
| TidepoolService | 0 | 13 | 0 | no |
| dexcom-share-client-swift | 0 | 8 | 0 | no |
| LibreLoop | 2 | 2 | 0 | `log.txt` via `LibreLoopFileLogger` |
| LibreCRKit | 0 | 0 | 1 | own `BLETimingLogger` |

Findings:

- AccuChekKit, DanaKit, EversenseKit, and MedtrumKit each carry a near-identical `Common/OSLog.swift` that wraps `os.Logger` and then re-implements `SimpleLogReporter`'s daily-rotation file writer. LibreLoop has a fifth variant. None of these files are collected by Trio's Share Logs. A user with a Dana pump who taps Share Logs sends a file that contains almost nothing about their pump.
- AccuChekKit and LibreCRKit never call the LoopKit device log at all. EversenseKit and RileyLinkKit call it once.
- OmnipodKit and LibreTransmitter still contain dozens of `print` statements in non-test code.
- The "deviceLog" numbers are low across the board because most kits log the interesting BLE traffic through `os_log` and reserve `logDeviceCommunication` for a handful of high-level events. Loop tolerates this because its Layer A can be captured by a `LoggingService`. Trio has no equivalent capture, so that traffic is lost.

### 3.6 Other places Trio keeps diagnostic state

- **Oref state files.** `OpenAPS/Constants.swift` names roughly 60 JSON files under `Documents` (`monitor/`, `enact/`, `settings/`, `upload/`). These are a complete snapshot of algorithm inputs and outputs and are exactly what a maintainer asks for after "Share Logs" turns out to be insufficient. They are not shared.
- **Core Data.** `TrioCoreDataPersistentContainer` has 17 entities including `OrefDetermination`, `GlucoseStored`, `PumpEventStored`, `CarbEntryStored`, `OverrideRunStored`, `TempTargetRunStored`, and `LoopStatRecord`. There is no log entity and no export path.
- **Alerts.** `BaseAlertHistoryStorage` keeps `[AlertEntry]` encoded in `UserDefaults`. It is not included in any log or report.
- **Watch.** `WatchLogger` (an actor on the watch) buffers up to 500 lines and pushes them over `WCSession` every three minutes or 100 lines. `AppleWatchManager` appends them to `Documents/logs/watch_log.txt` with its own copy of the rotation code. Not shared.
- **Crash reporting.** Firebase Crashlytics, opt-out, gated by `CrashReportingGate`. It is not wired to `IssueReporter`, so `warning(...)` non-fatals are dropped.
- **Algorithm test shim.** `AlgorithmLoggingShim.swift` re-declares the free functions for the SPM algorithm package. Any API change to the logger must be mirrored there.

### 3.7 Gap matrix

| Capability | Loop | Trio |
|---|---|---|
| Device comm log persisted with type and identifiers | Yes, Core Data, 7+ days | No, flattened into text |
| Device manager state dump in report | Yes, `debugDescription` | No |
| App-level log persisted locally | No (unified log + plugins only) | Yes, plain text, 24 to 48 h |
| Log levels queryable | Device log: type only. App: OS level | No |
| Retention policy | Days, configurable | One calendar-day rotation |
| Structured export | Yes, JSON per store, zipped daily | No |
| Human-readable report with build/settings/device state | Yes | No |
| Alerts in report | Yes | No |
| Algorithm inputs/outputs in report | Effects and predictions, 24 h samples | No (files exist but not bundled) |
| Watch logs in report | Watch manager state only | No (file exists but not bundled) |
| Kit-owned log files | None | Five kits, none collected |
| Plugin log fan-out (`LoggingService`) | Yes | No |
| In-app log viewer | No | No |
| Async, non-blocking log writes | Device log: yes. App: `os_log` only | No |
| Redaction of identifiers in report | Partial (OSLog privacy on args) | No |

## 4. Critique of Loop's approach

The user's instinct is right that Loop's design should not be copied one-to-one. Specific problems:

1. **Two overlapping export formats.** The markdown report and the critical event zip cover much of the same data in different shapes. Users and maintainers have to know which one to ask for. The zip is machine-readable but nobody has a reader; the markdown is readable but not parseable.
2. **App-level messages are not persisted.** Everything logged through `DiagnosticLog` is gone unless a `LoggingService` plugin captured it. Loop's report therefore has rich *state* but almost no *narrative* of what the app did between loop cycles.
3. **Report assembly is a completion-handler pyramid** that concatenates strings. Adding a section means editing a nested closure in `LoopDataManager`. There is no protocol for "things that contribute to a report."
4. **Magic windows.** 84 hours for alerts and device log, 24 hours for glucose samples, 100-row alert cap. None are explained or configurable.
5. **Purge only on read.** `PersistentDeviceLog` purges expired rows when someone fetches or exports. A device that never opens the report accumulates until the next export.
6. **`fatalError` on store load failure** in `PersistentDeviceLog.init`. A corrupt log database should never take down an insulin-dosing app.
7. **Privacy.** The report includes `UIDevice.name` (often the user's real name) and every kit's `debugDescription` verbatim. Nothing redacts serials, Nightscout URLs, or names before the file leaves the phone.
8. **`StaticString` format API.** `os_log` with `StaticString` and `CVarArg` is awkward, pushes people toward `%{public}@` everywhere, and predates `os.Logger` string interpolation with per-argument privacy.
9. **Kit helper duplication.** `logDeviceCommunication` is copied into every kit rather than provided by LoopKit as a protocol extension.

Things Loop gets right and Trio should keep: Core Data as the store with a retention window; a separate persistent container for logs so the main data model is not coupled to log schema changes; `modificationCounter` for streaming export; the `CriticalEventLog` protocol shape; letting `debugDescription` carry device state; background export scheduling; the report as a Markdown file so it reads well in GitHub issues.

## 5. Proposed target architecture for Trio

### 5.1 Principles

- One API for the whole app. Free functions can remain as thin shims during migration, but the type behind them changes.
- Immediate to the unified log, asynchronous to disk. Never block a caller on file or database I/O.
- Persist with structure: timestamp with sub-second precision, level, category, message, optional source location, launch identifier, and for device entries the manager identifier, device identifier, and type.
- One retention policy across app log and device log, in days, user-visible.
- One report, generated on demand, that includes everything a maintainer would otherwise ask for in a follow-up.
- De-identify by default. The report should be safe to attach to a public GitHub issue without editing.
- Kits log through LoopKit, not through their own files.

### 5.2 Components

**`TrioLogger` (replaces `Logger`).** A per-category value type wrapping `os.Logger(subsystem: "org.nightscout.Trio", category:)`. Levels `debug`, `info`, `notice`, `warning`, `error`, `fault`. `error` no longer crashes; a separate `preconditionFailure`-style helper covers the one current use. Each call writes to `os.Logger` synchronously (cheap, in-kernel buffer) and enqueues a `LogRecord` to a sink actor. Keep `#fileID`, `#function`, `#line` as defaults. Provide the same free-function names for the migration period and update `AlgorithmLoggingShim` in lockstep.

**`AppLogStore` (replaces `SimpleLogReporter`).** An actor that buffers `LogRecord`s and flushes to a dedicated `NSPersistentContainer` at `Documents/Logs/AppLog.sqlite` on a timer (for example every 2 seconds), on buffer size (for example 200 records), on `didEnterBackground`, and on `willTerminate`. Entity `AppLogEntry`: `timestamp` (Date), `level` (Int16), `category` (String, indexed), `message` (String), `file`, `function`, `line`, `launchID` (UUID). Retention purge runs on launch and once per day, batched, using `NSBatchDeleteRequest`. Never `fatalError`: if the store fails to load, fall back to an in-memory ring buffer and log a fault to the unified log.

**`PersistentDeviceLog` from LoopKit, unchanged.** Instantiate in `DeviceDataManager` at `Documents/Logs/DeviceLog.sqlite` with `maxEntryAge` from the shared retention setting. Fix both delegate implementations to forward `manager.pluginIdentifier`, `deviceIdentifier`, `type`, `message`, and `completion`. Optionally also mirror each entry into `os.Logger` under category `deviceComm` so Console shows both streams interleaved. Keeping Loop's exact store here means every existing kit's `logDeviceCommunication` starts working with no kit changes.

**`DiagnosticReportable` protocol.**

```swift
protocol DiagnosticReportable {
    var reportTitle: String { get }
    func generateDiagnosticReport(window: DateInterval) async -> String
}
```

Implemented by: `BuildDetails`, settings/preferences snapshot, `DeviceDataManager` (which includes `String(reflecting: pumpManager)` and `String(reflecting: cgmManager)`), `PersistentDeviceLog`, `AppLogStore`, `TrioAlertManager` history, `APSManager` (last determination, loop timing, `OrefDetermination` rows for the window), `AppleWatchManager` (state plus watch log), `NightscoutManager` (redacted URL, last upload results), and a `UIDevice` section without the device name. A `DiagnosticReportGenerator` takes an ordered `[DiagnosticReportable]`, runs them with `async let` or a task group, and joins the sections. No pyramid.

**Report bundle.** Replace "Share Logs" with "Generate Diagnostic Report." Output a zip containing `Trio Report <ISO date>.md` (the joined sections), the oref `monitor/`, `enact/`, and `settings/` JSON files, and `watch_log.txt`. Offer the markdown alone as a second option for quick GitHub pastes. Default window 3 days, selectable 1, 3, 7 days.

**Redaction pass.** Before the report leaves the process, run a `Redactor` over the markdown: replace Nightscout host names, API secrets, pump and transmitter serials (patterns from each kit), `UIDevice.name`, and e-mail-shaped strings with stable placeholders (`<pump-serial-1>`). Kits' `debugDescription`s are the main source of serials, so the redactor needs a per-kit pattern list maintained in Trio, not in the kits. Apply the same pass to the device and app log sections.

**Structured export (phase 4).** Implement LoopKit's `CriticalEventLog` for `AppLogStore` and for the Core Data entities that matter for post-incident analysis (`GlucoseStored`, `PumpEventStored`, `BolusStored`, `TempBasalStored`, `CarbEntryStored`, `OrefDetermination`, `OverrideRunStored`, `TempTargetRunStored`). Copy Loop's `CriticalEventLogExportManager.swift` and `ZipArchive.swift` into Trio (MIT-licensed; `Locked`, `JSONStreamEncoder`, and `DataOutputStream` are already in LoopKit). Trio already depends on nothing for zipping, so `ZIPFoundation` becomes a new dependency, or use `NSFileCoordinator`-based zipping via `FileManager` on iOS 17 if avoiding the dependency matters. Schedule as a `BGProcessingTask` like Loop, or skip the daily archive and only do full export on demand. Recommendation: on-demand only for the first release. Loop's daily archives exist so that a device that is wiped still has recent history in a shared container, which is a use case Trio has not asked for.

**Unified-log capture as a supplement.** `OSLogStore(scope: .currentProcessIdentifier)` is available on iOS 15 and Trio targets iOS 17. At report time, read the current process's unified-log entries for Trio's subsystem and for each kit's subsystem (`com.bastiaanv.AccuChekKit`, `com.loopkit.OmniBLE`, and so on) and append them as a section. This captures the hundreds of `os_log` sites in kits that never touch `logDeviceCommunication`, without changing the kits. The limitation is that it covers only the current process lifetime, which is why the persisted stores remain the primary source.

**`LoggingService` fan-out (optional).** Trio has Tidepool as a service already. Adding a `LoggingServicesManager` equivalent behind the sink actor costs little once the sink exists, and allows a future Nightscout or Tidepool service to receive app logs. Not needed for the refactor itself.

### 5.3 Kit policy

Propose to the `loopandlearn` fork maintainers, and apply to Trio's own `Trio/` target:

- Device I/O (bytes sent and received, connection state, errors from the device or its SDK) goes through `logDeviceCommunication` with the correct `DeviceLogEntryType`. This is the only channel Trio persists across launches.
- Internal diagnostics go through `os.Logger` with the kit's own subsystem and a meaningful category. No `print`, no `NSLog`.
- Kits do not write files. Remove the file-writer half of `Common/OSLog.swift` in AccuChekKit, DanaKit, EversenseKit, and MedtrumKit, and `LibreLoopFileLogger`. If a kit maintainer wants a file for standalone use outside Trio, gate it behind a flag that the host app controls.
- Consider adding `logDeviceCommunication` as a protocol extension on `PumpManager` and `CGMManager` in the LoopKit fork so kits stop copying it.

### 5.4 Performance and safety notes

- The sink actor plus batched `save()` removes the global lock and the per-line `open`/`write`/`close`. Loop cycles currently emit tens of synchronous file writes; after the change they emit zero.
- Core Data in a separate container means a log schema migration can never block the main `TrioCoreDataPersistentContainer` from loading.
- Retention and size: at Trio's current rate (roughly 600 call sites, most on the loop cycle) a 7-day window is on the order of tens of megabytes. Add a hard row cap (for example 500k rows) as a backstop, purged oldest-first.
- Never `fatalError` in the logging path. Logging must degrade, not crash.
- Report generation runs off the main actor with a `UIApplication.beginBackgroundTask` wrapper, as Loop's full exporter does, so a user who backgrounds the app mid-generation still gets the file.

### 5.5 Migration plan

| Phase | Scope | Notes |
|---|---|---|
| 0 | Instantiate `PersistentDeviceLog`; fix both delegate implementations; add the device log to the existing Share Logs output as a third file (`DeviceLog.txt` dumped from `getLogEntries`) | Two files touched plus one new line in `logItems()`. Ship first. |
| 1 | Introduce `TrioLogger` and the sink actor behind the existing free functions; `os.Logger` replaces `os_log`; `error` stops crashing; update `AlgorithmLoggingShim` | No call-site changes. Remove `loggerLock`. |
| 2 | `AppLogStore` in Core Data; retention setting; retire `SimpleLogReporter`; route watch logs into `AppLogStore` under category `watch` | Delete `logs/*.txt` on first launch after migration. |
| 3 | `DiagnosticReportable`, `DiagnosticReportGenerator`, redactor, report bundle UI replacing Share Logs; include oref JSON files | Largest UI change. Reuse `SettingsExport` module patterns for the share sheet. |
| 4 | `CriticalEventLog` implementations and on-demand structured export | Adds `ZIPFoundation` or equivalent. |
| 5 | Kit policy PRs upstream; remove kit file loggers; `OSLogStore` capture section | Can proceed in parallel with 3 and 4. |
| 6 | Sweep the 25 `print` sites and the 142 `.default` category sites into real categories; delete `Signpost.swift` or wire it | Mechanical. |

### 5.6 Decisions for maintainers

1. Retention default: 7 days to match LoopKit's `PersistentDeviceLog` default, or 3 days to bound disk use on older phones.
2. Whether to include oref JSON state files in the default bundle or behind a "detailed" toggle. They are the most useful and the most sensitive content.
3. Whether to take on `ZIPFoundation` now (phase 3 needs zipping for the bundle) or ship phase 3 as a markdown file plus separately shared JSON files.
4. Whether `TrioLogger.error` should also send a Crashlytics non-fatal when telemetry is enabled, restoring the intent behind `IssueReporter.reportNonFatalIssue`.
5. Whether the `loopandlearn` kit forks will accept removal of their file loggers, or whether Trio should instead collect those files into the bundle as an interim step.

## 6. File map

Loop and LoopKit:

- `LoopKit/LoopKit/DeviceManager/DeviceManager.swift` (delegate declaration)
- `LoopKit/LoopKit/DeviceManager/DeviceLog/PersistentDeviceLog.swift`, `DeviceLogEntryType.swift`, `StoredDeviceLogEntry.swift`, `DeviceLog.xcdatamodeld`
- `LoopKit/LoopKit/CriticalEventLog.swift`, `JSONStreamEncoder.swift`, `DataOutputStream.swift`, `Locked.swift`
- `LoopKit/LoopKit/Service/LoggingService.swift`, `LoopKit/LoopKit/Extensions/OSLog.swift`
- `Loop/Loop/Extensions/DiagnosticLog.swift`, `Loop/Loop/Managers/SharedLogging.swift`, `LoggingServicesManager.swift`
- `Loop/Loop/Managers/DeviceDataManager.swift` (device log creation around line 258, delegate at 950, report at 1709, background task at 1473)
- `Loop/Loop/Managers/LoopDataManager.swift` (report at 2211)
- `Loop/Loop/Managers/CriticalEventLogExportManager.swift`, `Loop/Loop/Models/ZipArchive.swift`
- `Loop/Loop/View Controllers/CommandResponseViewController.swift`, `Loop/Loop/Views/SettingsView.swift` (support section), `CriticalEventLogExportView.swift`

Trio:

- `Trio/Sources/Logger/Logger.swift`, `Signpost.swift`, `IssueReporter/IssueReporter.swift`, `CollectionIssueReporter.swift`, `SimpleLogReporter.swift`
- `Trio/Sources/Assemblies/ServiceAssembly.swift` (reporter registration)
- `Trio/Sources/APS/DeviceDataManager.swift` (delegate around line 634), `Trio/Sources/APS/CGM/PluginSource.swift` (delegate around line 93)
- `Trio/Sources/APS/OpenAPSSwift/AlgorithmLoggingShim.swift`
- `Trio/Sources/Modules/Settings/SettingsStateModel.swift` (`logItems`), `View/SettingsRootView.swift` ("Share Logs")
- `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` (watch log intake), `Trio Watch App Extension/WatchLogger.swift`
- `Trio/Sources/APS/OpenAPS/Constants.swift` (oref state file names)
- `Trio/Sources/APS/Storage/AlertStorage.swift`, `Trio/Sources/Services/Alerts/TrioAlertManager.swift`
- `Trio/Sources/Services/Telemetry/CrashReportingGate.swift`
- Kit file loggers: `AccuChekKit/Common/OSLog.swift`, `DanaKit/Common/OSLog.swift`, `EversenseKit/Common/OSLog.swift`, `MedtrumKit/Common/OSLog.swift`, `LibreLoop/LibreLoop/Common/LibreLoopFileLogger.swift`
