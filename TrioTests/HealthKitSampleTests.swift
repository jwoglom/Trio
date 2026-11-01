import Foundation
import HealthKit
import Testing

@testable import Trio

@Suite("Apple Health sample checks") struct HealthKitSampleTests {
    let insulin = HKQuantityType(.insulinDelivery)
    let basalMetadata: [String: Any] = [HKMetadataKeyInsulinDeliveryReason: HKInsulinDeliveryReason.basal.rawValue]
    let start = Date()

    @Test("An insulin sample ending before it starts is skipped, not created") func reversedInsulinSample() {
        let end = start.addingTimeInterval(-53 * 60)

        #expect(
            HKQuantitySample.rejectionReason(
                type: insulin,
                unit: .internationalUnit(),
                value: 0,
                start: start,
                end: end,
                metadata: basalMetadata
            ) != nil
        )
        #expect(
            HKQuantitySample.checked(
                type: insulin,
                unit: .internationalUnit(),
                value: 0,
                start: start,
                end: end,
                metadata: basalMetadata
            ) == nil
        )
    }

    @Test("A zero-length bolus and a temp basal are created") func validInsulinSamples() {
        let bolus = HKQuantitySample.checked(
            type: insulin,
            unit: .internationalUnit(),
            value: 0.4,
            start: start,
            end: start,
            metadata: [HKMetadataKeyInsulinDeliveryReason: HKInsulinDeliveryReason.bolus.rawValue]
        )
        let tempBasal = HKQuantitySample.checked(
            type: insulin,
            unit: .internationalUnit(),
            value: 0.6,
            start: start,
            end: start.addingTimeInterval(30 * 60),
            metadata: basalMetadata
        )

        #expect(bolus?.quantity.doubleValue(for: .internationalUnit()) == 0.4)
        #expect(tempBasal?.endDate == start.addingTimeInterval(30 * 60))
    }

    @Test(
        "A negative or non-finite quantity is skipped",
        arguments: [-0.05, Double.nan, Double.infinity]
    ) func invalidQuantity(value: Double) {
        #expect(
            HKQuantitySample.checked(
                type: insulin,
                unit: .internationalUnit(),
                value: value,
                start: start,
                end: start,
                metadata: basalMetadata
            ) == nil
        )
    }

    @Test("A unit the type does not measure in is skipped") func incompatibleUnit() {
        #expect(
            HKQuantitySample.checked(
                type: insulin,
                unit: .gram(),
                value: 1,
                start: start,
                end: start,
                metadata: basalMetadata
            ) == nil
        )
    }

    @Test("An insulin sample without a delivery reason is skipped") func insulinWithoutDeliveryReason() {
        #expect(
            HKQuantitySample.checked(
                type: insulin,
                unit: .internationalUnit(),
                value: 1,
                start: start,
                end: start,
                metadata: nil
            ) == nil
        )
    }
}
