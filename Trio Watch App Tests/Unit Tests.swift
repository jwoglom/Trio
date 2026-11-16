import SwiftUI
import Testing
import WatchConnectivity
@testable import Trio_Watch_App

@Suite("Watch App Tests", .serialized) @MainActor final class TrioWatchAppTests {
    var watchState = WatchState()

    /// Lets main-queue work scheduled by WatchState (asyncAfter, async) run
    private func waitForMainQueue(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    // MARK: - Color Conversion Tests

    @Test("Hex string to color conversion") func testHexStringToColor() throws {
        // Given
        let whiteHex = "#FFFFFF"
        let blackHex = "#000000"
        let redHex = "#FF0000"
        let invalidHex = "invalid"

        // Then
        #expect(whiteHex.toColor() == Color.white)
        #expect(blackHex.toColor() == Color.black)
        #expect(redHex.toColor() == Color(red: 1, green: 0, blue: 0))
        #expect(invalidHex.toColor() == Color.black)
    }

    // MARK: - WatchState Tests

    @Test("WatchState initialization with default values") func testWatchStateInitialization() throws {
        #expect(watchState.currentGlucose == "--")
        #expect(watchState.currentGlucoseColorString == "#ffffff")
        #expect(watchState.glucoseValues.isEmpty)
        #expect(watchState.iob == "--")
        #expect(watchState.cob == "--")
        #expect(watchState.lastLoopTime == "--")
    }

    @Test("Bolus limits have correct default values") func testBolusLimits() throws {
        #expect(watchState.maxBolus == Decimal(10))
        #expect(watchState.bolusIncrement == Decimal(0.05))
    }

    @Test("Carb limits have correct default values") func testCarbLimits() throws {
        #expect(watchState.maxCarbs == Decimal(250))
    }

    @Test("Acknowledgment states transition correctly") func testAcknowledgmentStates() async throws {
        // Given - Initial state
        #expect(watchState.acknowledgementStatus == .pending)
        #expect(!watchState.showAcknowledgmentBanner)

        // When/Then - Success acknowledgment
        watchState.handleAcknowledgment(success: true, message: "Success")
        #expect(watchState.acknowledgementStatus == .success)
        #expect(watchState.acknowledgmentMessage == "Success")
        try await waitForMainQueue(0.5)
        #expect(watchState.showAcknowledgmentBanner)

        // When/Then - Failure acknowledgment
        watchState.handleAcknowledgment(success: false, message: "Error")
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == "Error")
    }

    // MARK: - Reachability must not touch entries in progress

    @Test("Phone reconnecting keeps the bolus being confirmed") func testReconnectKeepsBolusEntry() throws {
        // Given - the user is on the confirm screen, partway through dialing the crown
        watchState.bolusAmount = 3.0
        watchState.carbsAmount = 20
        watchState.confirmationProgress = 0.5

        // When - raising the wrist reconnects the phone
        watchState.handleReachabilityChange(isReachable: false)
        watchState.handleReachabilityChange(isReachable: true)

        // Then - the confirmed amount is still the one the user entered, not 0 U
        #expect(watchState.bolusAmount == 3.0)
        #expect(watchState.carbsAmount == 20)
        #expect(watchState.confirmationProgress == 0.5)
    }

    // MARK: - Bolus requests that must not be sent

    @Test("Zero bolus is refused on the watch", arguments: [
        Decimal(0),
        Decimal(-1)
    ]) func testZeroBolusRefused(amount: Decimal) async throws {
        watchState.sendBolusRequest(amount)

        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.invalidBolusAmountMessage)
        try await waitForMainQueue(0.5)
        #expect(!watchState.showCommsAnimation)
        #expect(watchState.showAcknowledgmentBanner)
    }

    @Test("Bolus with the phone unreachable says nothing was sent") func testUnreachableBolus() async throws {
        watchState.session = nil

        watchState.sendBolusRequest(3)

        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.phoneUnreachableMessage)
        try await waitForMainQueue(0.5)
        #expect(!watchState.showCommsAnimation)
        #expect(watchState.showAcknowledgmentBanner)
    }

    @Test("Other treatment requests with the phone unreachable say nothing was sent") func testUnreachableTreatments() throws {
        watchState.session = nil
        let requests: [() -> Void] = [
            { self.watchState.sendCarbsRequest(20) },
            { self.watchState.sendCancelOverrideRequest() },
            { self.watchState.sendActivateOverrideRequest(presetName: "Exercise") },
            { self.watchState.sendCancelTempTargetRequest() },
            { self.watchState.sendActivateTempTargetRequest(presetName: "Eating soon") }
        ]

        for request in requests {
            watchState.acknowledgementStatus = .pending
            watchState.acknowledgmentMessage = ""
            request()
            #expect(watchState.acknowledgementStatus == .failure)
            #expect(watchState.acknowledgmentMessage == WatchState.phoneUnreachableMessage)
        }
    }

    // MARK: - Waiting for the phone's answer

    @Test("Processing ends with a check-your-phone message when the phone never answers") func testAcknowledgmentTimeout() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 0.1)
        #expect(watchState.showCommsAnimation)
        #expect(watchState.acknowledgementStatus == .pending)

        try await waitForMainQueue(0.6)

        #expect(!watchState.showCommsAnimation)
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.noAnswerMessage)
        #expect(watchState.showAcknowledgmentBanner)
    }

    @Test("An answer from the phone cancels the timeout") func testAcknowledgmentCancelsTimeout() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 0.1)

        watchState.handleAcknowledgment(success: true, message: "Bolus enacted successfully.")
        try await waitForMainQueue(0.6)

        #expect(watchState.acknowledgementStatus == .success)
        #expect(watchState.acknowledgmentMessage == "Bolus enacted successfully.")
    }

    @Test("A send error ends processing with the check-your-phone message") func testSendErrorEndsProcessing() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 60)

        // What the sendMessage error handler does
        watchState.handleMissingAcknowledgment()

        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.noAnswerMessage)
        try await waitForMainQueue(0.5)
        #expect(!watchState.showCommsAnimation)
    }

    @Test("A late timeout does not overwrite an answer already shown") func testMissingAcknowledgmentAfterAnswer() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 60)
        watchState.handleAcknowledgment(success: true, message: "Bolus enacted successfully.")
        try await waitForMainQueue(0.3)

        watchState.handleMissingAcknowledgment()

        #expect(watchState.acknowledgementStatus == .success)
        #expect(watchState.acknowledgmentMessage == "Bolus enacted successfully.")
    }

    // MARK: - Entries expire after 2 minutes

    private let entryStart = Date(timeIntervalSince1970: 1_800_000_000)

    /// An entry on the confirm screen: 20 g carbs and 3 U, last edited at `entryStart`
    private func enterMealBolus() {
        watchState.carbsAmount = 20
        watchState.bolusAmount = 3.0
        watchState.confirmationProgress = 0.5
        watchState.markEntryEdited(at: entryStart)
    }

    private func expectEntryCleared() {
        #expect(watchState.bolusAmount == 0)
        #expect(watchState.carbsAmount == 0)
        #expect(watchState.confirmationProgress == 0)
        #expect(watchState.entryEditedAt == nil)
    }

    @Test("An entry is fresh for 2 minutes after its last edit") func testEntryFreshness() throws {
        #expect(!watchState.isEntryFresh(at: entryStart), "no entry has been edited yet")

        watchState.markEntryEdited(at: entryStart)

        #expect(watchState.isEntryFresh(at: entryStart.addingTimeInterval(119)))
        #expect(watchState.isEntryFresh(at: entryStart.addingTimeInterval(120)))
        #expect(!watchState.isEntryFresh(at: entryStart.addingTimeInterval(121)))

        // Editing again restarts the clock
        watchState.markEntryEdited(at: entryStart.addingTimeInterval(100))
        #expect(watchState.isEntryFresh(at: entryStart.addingTimeInterval(200)))
    }

    @Test("Confirming an entry older than 2 minutes sends nothing and clears it")
    func testExpiredEntryNotSent() throws {
        enterMealBolus()

        watchState.sendConfirmedEntry(bolusAmount: 3.0, at: entryStart.addingTimeInterval(121))

        // The expired message, not "phone unreachable", shows nothing was attempted
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(watchState.acknowledgmentMessage == WatchState.entryExpiredMessage)
        expectEntryCleared()
    }

    @Test("Confirming an entry with no recorded edit sends nothing") func testUneditedEntryNotSent() throws {
        watchState.bolusAmount = 3.0

        watchState.sendConfirmedEntry(bolusAmount: 3.0, at: entryStart)

        #expect(watchState.acknowledgmentMessage == WatchState.entryExpiredMessage)
        expectEntryCleared()
    }

    @Test("Confirming a fresh entry sends it and clears it") func testFreshEntrySent() throws {
        enterMealBolus()
        // No phone in tests: reaching the "unreachable" refusal proves the send was attempted
        watchState.session = nil

        watchState.sendConfirmedEntry(bolusAmount: 3.0, at: entryStart.addingTimeInterval(60))

        #expect(watchState.acknowledgmentMessage == WatchState.phoneUnreachableMessage)
        expectEntryCleared()
    }

    @Test("Logging carbs older than 2 minutes sends nothing") func testExpiredCarbsNotSent() throws {
        watchState.markEntryEdited(at: entryStart)

        watchState.sendCarbsEntry(20, at: entryStart.addingTimeInterval(121))

        #expect(watchState.acknowledgmentMessage == WatchState.entryExpiredMessage)
        expectEntryCleared()
    }

    @Test("Logging fresh carbs sends them") func testFreshCarbsSent() throws {
        watchState.markEntryEdited(at: entryStart)
        watchState.session = nil

        watchState.sendCarbsEntry(20, at: entryStart.addingTimeInterval(60))

        #expect(watchState.acknowledgmentMessage == WatchState.phoneUnreachableMessage)
        expectEntryCleared()
    }

    @Test("Returning to the app clears an entry older than 2 minutes") func testStaleEntryExpiresOnReturn() throws {
        enterMealBolus()

        #expect(!watchState.expireStaleEntry(at: entryStart.addingTimeInterval(120)))
        #expect(watchState.bolusAmount == 3.0)

        #expect(watchState.expireStaleEntry(at: entryStart.addingTimeInterval(121)))
        expectEntryCleared()
    }

    @Test("Returning to the app with no entry in progress changes nothing") func testNoEntryOnReturn() throws {
        #expect(!watchState.expireStaleEntry(at: entryStart))
    }

    // MARK: - Bolus refused while the pump is bolusing

    /// The phone's answer when it refused a bolus because the pump was already bolusing
    private func bolusInProgressAck(amount: Double?) -> [String: Any] {
        var message: [String: Any] = [
            WatchMessageKeys.acknowledged: false,
            WatchMessageKeys.message: "Pump is already delivering a bolus. Nothing was sent to the pump.",
            WatchMessageKeys.ackCode: AcknowledgmentCode.bolusInProgress.rawValue
        ]
        if let amount { message[WatchMessageKeys.bolus] = amount }
        return message
    }

    @Test("A bolus refused while the pump is bolusing offers a retry of that amount") func testBolusInProgressOffersRetry() async throws {
        watchState.beginAwaitingAcknowledgment(timeout: 0.2)

        watchState.session(WCSession.default, didReceiveMessage: bolusInProgressAck(amount: 2.5))
        try await waitForMainQueue(0.6)

        #expect(watchState.refusedBolus?.amount == 2.5)
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(!watchState.showCommsAnimation)
        // No banner: it would close the screen after 2 seconds; the late timeout must not show one either
        #expect(!watchState.showAcknowledgmentBanner)
        #expect(watchState.acknowledgmentMessage != WatchState.noAnswerMessage)
    }

    @Test("A refusal without the amount is shown as a plain failure") func testBolusInProgressWithoutAmount() async throws {
        watchState.handleBolusRefusedWhileBolusing(amount: nil, message: "Pump is bolusing")

        #expect(watchState.refusedBolus == nil)
        #expect(watchState.acknowledgementStatus == .failure)
        try await waitForMainQueue(0.5)
        #expect(watchState.showAcknowledgmentBanner)
    }

    @Test("A late carbs answer keeps the retry offer and notes the carbs") func testCarbsAckKeepsRetry() async throws {
        watchState.handleBolusRefusedWhileBolusing(amount: 2.5, message: "busy")

        watchState.session(WCSession.default, didReceiveMessage: [
            WatchMessageKeys.acknowledged: true,
            WatchMessageKeys.message: "Carbs logged successfully.",
            WatchMessageKeys.ackCode: AcknowledgmentCode.carbsLogged.rawValue
        ])
        try await waitForMainQueue(0.6)

        #expect(watchState.refusedBolus?.amount == 2.5)
        #expect(watchState.refusedBolus?.carbsLogged == true)
        #expect(watchState.acknowledgementStatus == .failure)
        #expect(!watchState.showAcknowledgmentBanner)
    }

    @Test("Carbs logged just before the refusal are noted") func testCarbsAckBeforeRefusal() async throws {
        watchState.session(WCSession.default, didReceiveMessage: [
            WatchMessageKeys.acknowledged: true,
            WatchMessageKeys.message: "Carbs logged successfully.",
            WatchMessageKeys.ackCode: AcknowledgmentCode.carbsLogged.rawValue
        ])
        watchState.session(WCSession.default, didReceiveMessage: bolusInProgressAck(amount: 1.0))
        try await waitForMainQueue(0.6)

        #expect(watchState.refusedBolus?.carbsLogged == true)
    }

    @Test("Retrying loads only the bolus as a fresh entry to confirm again") func testRetryLoadsBolusOnly() throws {
        enterMealBolus()
        watchState.handleBolusRefusedWhileBolusing(amount: 3.0, message: "busy", at: entryStart)
        let retryAt = entryStart.addingTimeInterval(90)

        #expect(watchState.prepareRefusedBolusRetry(at: retryAt))

        #expect(watchState.refusedBolus == nil)
        #expect(watchState.bolusAmount == 3.0)
        #expect(watchState.carbsAmount == 0, "carbs were sent separately and must not be sent twice")
        #expect(watchState.confirmationProgress == 0, "the crown must be dialed again")
        #expect(watchState.isEntryFresh(at: retryAt))
    }

    @Test("A retry offer older than 2 minutes sends nothing") func testRetryExpires() throws {
        watchState.handleBolusRefusedWhileBolusing(amount: 3.0, message: "busy", at: entryStart)

        #expect(!watchState.prepareRefusedBolusRetry(at: entryStart.addingTimeInterval(121)))

        #expect(watchState.refusedBolus == nil)
        #expect(watchState.bolusAmount == 0)
        #expect(watchState.acknowledgmentMessage == WatchState.bolusRetryExpiredMessage)
    }

    @Test("Returning to the app drops a retry offer older than 2 minutes") func testStaleRetryExpiresOnReturn() throws {
        watchState.handleBolusRefusedWhileBolusing(amount: 3.0, message: "busy", at: entryStart)

        #expect(!watchState.expireStaleBolusRetry(at: entryStart.addingTimeInterval(120)))
        #expect(watchState.refusedBolus != nil)

        #expect(watchState.expireStaleBolusRetry(at: entryStart.addingTimeInterval(121)))
        #expect(watchState.refusedBolus == nil)
    }

    @Test("Dismissing or sending a new request clears the retry offer") func testRetryOfferCleared() throws {
        watchState.handleBolusRefusedWhileBolusing(amount: 3.0, message: "busy")
        watchState.dismissRefusedBolus()
        #expect(watchState.refusedBolus == nil)

        watchState.handleBolusRefusedWhileBolusing(amount: 3.0, message: "busy")
        watchState.beginAwaitingAcknowledgment(timeout: 60)
        #expect(watchState.refusedBolus == nil)
    }
}
