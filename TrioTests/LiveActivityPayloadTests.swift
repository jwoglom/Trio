import Foundation
import Testing

@testable import Trio

/// Tests for the size of a Live Activity's content state and for the compact chart
/// encoding that keeps it small.
///
/// ActivityKit caps a content state at 4096 bytes of JSON and rejects anything larger
/// with "Payload maximum size exceeded". `Activity.update(_:)` does not throw, so a
/// rejected update leaves the Live Activity frozen on whatever it last accepted — for a
/// freshly created activity, the `isInitialState` placeholder reading "Live Activity
/// Expired". A payload regression is therefore silent on device, which is what these
/// tests exist to catch.
///
/// The 4096-byte limit is measured against `JSONEncoder` output: the placeholder state
/// measured 642 bytes on device and 644 bytes through `JSONEncoder`, so
/// `encodedPayloadSize` is the right yardstick.
@Suite("Live Activity Payload Tests") struct LiveActivityPayloadTests {
    /// ActivityKit's hard limit. Exceeding it means the update never reaches the widget.
    private static let activityKitLimit = 4096

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    /// A glucose series `count` readings long at a five-minute cadence, newest first —
    /// the order `fetchAndMapGlucose` returns.
    private func chart(count: Int) -> [LiveActivityAttributes.ChartItem] {
        (0 ..< count).map { index in
            LiveActivityAttributes.ChartItem(
                value: Decimal(100 + index % 80),
                date: anchor.addingTimeInterval(-300 * Double(index))
            )
        }
    }

    private func forecast(count: Int = 24) -> [Int] {
        (0 ..< count).map { 100 + $0 % 30 }
    }

    private func forecastLines(count: Int = 24) -> [LiveActivityAttributes.ForecastLine] {
        ["cob", "uam", "zt"].map {
            LiveActivityAttributes.ForecastLine(type: $0, values: (0 ..< count).map { 100 + $0 % 30 })
        }
    }

    /// A content state carrying the most expensive realistic combination of fields: an
    /// active override with a name, an active temp target, four widget items and a
    /// forecast.
    private func state(
        chart: [LiveActivityAttributes.ChartItem],
        minForecast: [Int] = [],
        maxForecast: [Int] = [],
        forecastLines: [LiveActivityAttributes.ForecastLine] = []
    ) -> LiveActivityAttributes.ContentState {
        LiveActivityAttributes.ContentState(
            unit: "mg/dL",
            bg: "118",
            direction: "→",
            change: "+2",
            date: anchor,
            highGlucose: 180,
            lowGlucose: 70,
            target: 100,
            glucoseColorScheme: "dynamicColor",
            useDetailedViewIOS: true,
            useDetailedViewWatchOS: true,
            detailedViewState: LiveActivityAttributes.ContentAdditionalState(
                chart: chart,
                rotationDegrees: 0,
                cob: 25,
                iob: 2.5,
                tdd: 45.3,
                isOverrideActive: true,
                overrideName: "Exercise",
                overrideDate: anchor.addingTimeInterval(-3600),
                overrideDuration: 120,
                overrideTarget: 150,
                isTempTargetActive: true,
                tempTargetName: "Temp Target",
                tempTargetDate: anchor.addingTimeInterval(-1800),
                tempTargetDuration: 60,
                tempTargetTarget: 120,
                widgetItems: LiveActivityAttributes.LiveActivityItem.defaultItems,
                minForecast: minForecast,
                maxForecast: maxForecast,
                forecastLines: forecastLines,
                forecastDisplayType: "cone"
            ),
            isInitialState: false
        )
    }

    // MARK: - Compact chart encoding

    @Test("The compact chart storage round-trips values and dates") func testChartRoundTrip() {
        let original = chart(count: 12)
        let additionalState = state(chart: original).detailedViewState

        #expect(additionalState.chartValues.count == original.count)
        #expect(additionalState.chartOffsets.count == original.count)
        // The anchor is the newest reading, so the newest point carries a zero offset.
        #expect(additionalState.chartAnchor == anchor)
        #expect(additionalState.chartOffsets.first == 0)

        let rebuilt = additionalState.chart
        #expect(rebuilt.count == original.count)
        for (rebuiltItem, originalItem) in zip(rebuilt, original) {
            #expect(rebuiltItem.value == originalItem.value)
            #expect(rebuiltItem.date == originalItem.date)
        }
    }

    @Test("An empty chart round-trips as empty rather than trapping") func testEmptyChartRoundTrip() {
        let additionalState = state(chart: []).detailedViewState

        #expect(additionalState.chartValues.isEmpty)
        #expect(additionalState.chartOffsets.isEmpty)
        #expect(additionalState.chart.isEmpty)
    }

    @Test("Out-of-range readings clamp instead of trapping") func testExtremeReadingsClamp() {
        // A corrupt reading must not crash the app on an Int16 conversion.
        let extremes = [
            LiveActivityAttributes.ChartItem(value: Decimal(500_000), date: anchor),
            LiveActivityAttributes.ChartItem(value: Decimal(-500_000), date: anchor.addingTimeInterval(-300))
        ]
        let additionalState = state(chart: extremes).detailedViewState

        #expect(additionalState.chartValues == [Int16.max, Int16.min])
    }

    // MARK: - Payload size

    @Test("A six-hour chart with a forecast cone fits with room to spare") func testRealisticPayloadFits() {
        let payload = state(
            chart: chart(count: 72),
            minForecast: forecast(),
            maxForecast: forecast()
        ).encodedPayloadSize

        #expect(payload < Self.activityKitLimit)
        #expect(payload <= LiveActivityAttributes.ContentState.maxPayloadBytes)
    }

    @Test("A six-hour chart with forecast lines fits with room to spare") func testForecastLinesPayloadFits() {
        let payload = state(chart: chart(count: 72), forecastLines: forecastLines()).encodedPayloadSize

        #expect(payload < Self.activityKitLimit)
        #expect(payload <= LiveActivityAttributes.ContentState.maxPayloadBytes)
    }

    /// Duplicate rows in the six-hour window are what pushed the old `[ChartItem]`
    /// encoding over the limit: at ~31 bytes per reading it only took about 103 readings
    /// to exceed 4096 bytes.
    @Test("Duplicated readings no longer exceed ActivityKit's limit") func testDuplicatedReadingsFit() {
        let payload = state(
            chart: chart(count: 144),
            minForecast: forecast(),
            maxForecast: forecast()
        ).encodedPayloadSize

        #expect(payload < Self.activityKitLimit)
    }

    @Test("The guard threshold leaves headroom under ActivityKit's limit") func testGuardBelowHardLimit() {
        #expect(LiveActivityAttributes.ContentState.maxPayloadBytes < Self.activityKitLimit)
    }

    // MARK: - Shedding detail

    @Test("Thinning keeps the newest reading and drops the rest evenly") func testSheddingThinsChart() {
        let full = state(chart: chart(count: 10), minForecast: forecast(), maxForecast: forecast())
            .detailedViewState
        let thinned = full.shedding(chartStride: 2, keepForecasts: true)

        #expect(thinned.chartValues.count == 5)
        // The newest reading must survive — it is the one the user reads.
        #expect(thinned.chartValues.first == full.chartValues.first)
        #expect(thinned.chartOffsets.first == 0)
        #expect(thinned.chartValues == [
            full.chartValues[0],
            full.chartValues[2],
            full.chartValues[4],
            full.chartValues[6],
            full.chartValues[8]
        ])
        #expect(thinned.minForecast == full.minForecast)
    }

    @Test("Shedding can drop the forecast and the chart entirely") func testSheddingDropsForecastAndChart() {
        let full = state(chart: chart(count: 10), minForecast: forecast(), maxForecast: forecast())
            .detailedViewState

        let withoutForecast = full.shedding(chartStride: 1, keepForecasts: false)
        #expect(withoutForecast.chartValues.count == 10)
        #expect(withoutForecast.minForecast.isEmpty)
        #expect(withoutForecast.maxForecast.isEmpty)
        #expect(withoutForecast.forecastLines.isEmpty)

        let withoutChart = full.shedding(chartStride: 0, keepForecasts: true)
        #expect(withoutChart.chartValues.isEmpty)
        #expect(withoutChart.chartOffsets.isEmpty)
        #expect(withoutChart.minForecast == full.minForecast)
    }

    @Test("Shedding preserves every field it is not asked to drop") func testSheddingPreservesOtherFields() {
        let full = state(chart: chart(count: 10), minForecast: forecast(), maxForecast: forecast())
            .detailedViewState
        let thinned = full.shedding(chartStride: 2, keepForecasts: true)

        #expect(thinned.chartAnchor == full.chartAnchor)
        #expect(thinned.cob == full.cob)
        #expect(thinned.iob == full.iob)
        #expect(thinned.tdd == full.tdd)
        #expect(thinned.isOverrideActive == full.isOverrideActive)
        #expect(thinned.overrideName == full.overrideName)
        #expect(thinned.overrideDate == full.overrideDate)
        #expect(thinned.isTempTargetActive == full.isTempTargetActive)
        #expect(thinned.tempTargetName == full.tempTargetName)
        #expect(thinned.widgetItems == full.widgetItems)
        #expect(thinned.forecastDisplayType == full.forecastDisplayType)
    }

    // MARK: - Fitting to the limit

    @Test("A state that already fits is returned untouched") func testFittingLeavesSmallStateAlone() {
        let original = state(chart: chart(count: 72), minForecast: forecast(), maxForecast: forecast())

        #expect(original.fittedToPayloadLimit() == original)
    }

    @Test("An oversized state is reduced under the guard threshold") func testFittingReducesOversizedState() {
        // Far more readings than six hours can hold, standing in for a pathological
        // duplicate-row count.
        let oversized = state(chart: chart(count: 600), forecastLines: forecastLines())
        #expect(oversized.encodedPayloadSize > LiveActivityAttributes.ContentState.maxPayloadBytes)

        let fitted = oversized.fittedToPayloadLimit()

        #expect(fitted.encodedPayloadSize <= LiveActivityAttributes.ContentState.maxPayloadBytes)
        #expect(fitted.encodedPayloadSize < Self.activityKitLimit)
        // Reducing detail must not disturb the numbers the user actually reads.
        #expect(fitted.bg == oversized.bg)
        #expect(fitted.change == oversized.change)
        #expect(fitted.date == oversized.date)
        #expect(fitted.isInitialState == oversized.isInitialState)
        #expect(fitted.detailedViewState.iob == oversized.detailedViewState.iob)
        #expect(fitted.detailedViewState.cob == oversized.detailedViewState.cob)
        // The newest reading survives every rung of the fallback ladder.
        #expect(fitted.detailedViewState.chartValues.first == oversized.detailedViewState.chartValues.first)
    }

    @Test("Fitting sheds the chart before the forecast") func testFittingPrefersKeepingForecast() {
        // At this size thinning the series is enough, so the forecast should still be
        // there: a prediction is worth more than every other glucose point.
        let oversized = state(chart: chart(count: 400), minForecast: forecast(), maxForecast: forecast())
        #expect(oversized.encodedPayloadSize > LiveActivityAttributes.ContentState.maxPayloadBytes)

        let fitted = oversized.fittedToPayloadLimit()

        #expect(fitted.detailedViewState.chartValues.count < oversized.detailedViewState.chartValues.count)
        #expect(fitted.detailedViewState.minForecast == oversized.detailedViewState.minForecast)
        #expect(fitted.detailedViewState.maxForecast == oversized.detailedViewState.maxForecast)
    }

    @Test("Even an absurd chart is forced under the limit") func testFittingHandlesAbsurdChart() {
        let absurd = state(chart: chart(count: 5000), forecastLines: forecastLines())

        let fitted = absurd.fittedToPayloadLimit()

        #expect(fitted.encodedPayloadSize < Self.activityKitLimit)
    }
}
