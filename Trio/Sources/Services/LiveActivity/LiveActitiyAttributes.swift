import ActivityKit
import Foundation

struct LiveActivityAttributes: ActivityAttributes {
    enum LiveActivityItem: String, Hashable, Codable, Equatable {
        case currentGlucoseLarge
        case currentGlucose
        case iob
        case cob
        case updatedLabel
        case totalDailyDose
        case empty

        static let defaultItems: [Self] = [.currentGlucoseLarge, .iob, .cob, .updatedLabel]
    }

    struct ContentState: Codable, Hashable {
        let unit: String
        let bg: String
        let direction: String?
        let change: String
        let date: Date?
        let highGlucose: Decimal
        let lowGlucose: Decimal
        let target: Decimal
        let glucoseColorScheme: String
        let useDetailedViewIOS: Bool
        let useDetailedViewWatchOS: Bool
        let detailedViewState: ContentAdditionalState

        /// true for the first state that is set on the activity
        let isInitialState: Bool
    }

    struct ContentAdditionalState: Codable, Hashable {
        /// The glucose chart is stored as an anchor date plus parallel value/offset
        /// arrays rather than as `[ChartItem]`. ActivityKit rejects any content state
        /// whose JSON encoding exceeds 4 KB ("Payload maximum size exceeded"), and a
        /// dictionary per point spent ~38 bytes each — six hours of readings alone ate
        /// most of the budget. Reconstruct the points via ``chart``.
        let chartAnchor: Date
        /// Glucose values in mg/dL, in the same order the readings were fetched.
        let chartValues: [Int16]
        /// Seconds before ``chartAnchor`` for each entry in ``chartValues``.
        let chartOffsets: [Int32]
        let rotationDegrees: Double
        let cob: Decimal
        let iob: Decimal
        let tdd: Decimal
        let isOverrideActive: Bool
        let overrideName: String
        let overrideDate: Date
        let overrideDuration: Decimal
        let overrideTarget: Decimal
        let isTempTargetActive: Bool
        let tempTargetName: String
        let tempTargetDate: Date
        let tempTargetDuration: Decimal
        let tempTargetTarget: Decimal
        let widgetItems: [LiveActivityItem]
        let minForecast: [Int]
        let maxForecast: [Int]
        let forecastLines: [ForecastLine]
        let forecastDisplayType: String

        /// The glucose chart, rebuilt from the compact anchor/value/offset storage.
        var chart: [ChartItem] {
            zip(chartValues, chartOffsets).map { value, offset in
                ChartItem(
                    value: Decimal(value),
                    date: chartAnchor.addingTimeInterval(-Double(offset))
                )
            }
        }

        init(
            chartAnchor: Date,
            chartValues: [Int16],
            chartOffsets: [Int32],
            rotationDegrees: Double,
            cob: Decimal,
            iob: Decimal,
            tdd: Decimal,
            isOverrideActive: Bool,
            overrideName: String,
            overrideDate: Date,
            overrideDuration: Decimal,
            overrideTarget: Decimal,
            isTempTargetActive: Bool,
            tempTargetName: String,
            tempTargetDate: Date,
            tempTargetDuration: Decimal,
            tempTargetTarget: Decimal,
            widgetItems: [LiveActivityItem],
            minForecast: [Int],
            maxForecast: [Int],
            forecastLines: [ForecastLine],
            forecastDisplayType: String
        ) {
            self.chartAnchor = chartAnchor
            self.chartValues = chartValues
            self.chartOffsets = chartOffsets
            self.rotationDegrees = rotationDegrees
            self.cob = cob
            self.iob = iob
            self.tdd = tdd
            self.isOverrideActive = isOverrideActive
            self.overrideName = overrideName
            self.overrideDate = overrideDate
            self.overrideDuration = overrideDuration
            self.overrideTarget = overrideTarget
            self.isTempTargetActive = isTempTargetActive
            self.tempTargetName = tempTargetName
            self.tempTargetDate = tempTargetDate
            self.tempTargetDuration = tempTargetDuration
            self.tempTargetTarget = tempTargetTarget
            self.widgetItems = widgetItems
            self.minForecast = minForecast
            self.maxForecast = maxForecast
            self.forecastLines = forecastLines
            self.forecastDisplayType = forecastDisplayType
        }

        init(
            chart: [ChartItem],
            rotationDegrees: Double,
            cob: Decimal,
            iob: Decimal,
            tdd: Decimal,
            isOverrideActive: Bool,
            overrideName: String,
            overrideDate: Date,
            overrideDuration: Decimal,
            overrideTarget: Decimal,
            isTempTargetActive: Bool,
            tempTargetName: String,
            tempTargetDate: Date,
            tempTargetDuration: Decimal,
            tempTargetTarget: Decimal,
            widgetItems: [LiveActivityItem],
            minForecast: [Int],
            maxForecast: [Int],
            forecastLines: [ForecastLine],
            forecastDisplayType: String
        ) {
            let anchor = chart.map(\.date).max() ?? Date.now
            chartAnchor = anchor
            chartValues = chart.map { Int16(clamping: ($0.value as NSDecimalNumber).intValue) }
            chartOffsets = chart.map { Int32(clamping: Int(anchor.timeIntervalSince($0.date).rounded())) }
            self.rotationDegrees = rotationDegrees
            self.cob = cob
            self.iob = iob
            self.tdd = tdd
            self.isOverrideActive = isOverrideActive
            self.overrideName = overrideName
            self.overrideDate = overrideDate
            self.overrideDuration = overrideDuration
            self.overrideTarget = overrideTarget
            self.isTempTargetActive = isTempTargetActive
            self.tempTargetName = tempTargetName
            self.tempTargetDate = tempTargetDate
            self.tempTargetDuration = tempTargetDuration
            self.tempTargetTarget = tempTargetTarget
            self.widgetItems = widgetItems
            self.minForecast = minForecast
            self.maxForecast = maxForecast
            self.forecastLines = forecastLines
            self.forecastDisplayType = forecastDisplayType
        }

        /// Returns a copy carrying less chart detail, used to fit inside ActivityKit's
        /// payload limit: `chartStride` keeps every nth point (1 keeps all, 0 drops the
        /// chart entirely) and `keepForecasts` drops the forecast cone and lines.
        func shedding(chartStride: Int, keepForecasts: Bool) -> Self {
            func thinned<T>(_ values: [T]) -> [T] {
                guard chartStride > 0 else { return [] }
                guard chartStride > 1 else { return values }
                return values.enumerated().filter { $0.offset.isMultiple(of: chartStride) }.map(\.element)
            }

            return Self(
                chartAnchor: chartAnchor,
                chartValues: thinned(chartValues),
                chartOffsets: thinned(chartOffsets),
                rotationDegrees: rotationDegrees,
                cob: cob,
                iob: iob,
                tdd: tdd,
                isOverrideActive: isOverrideActive,
                overrideName: overrideName,
                overrideDate: overrideDate,
                overrideDuration: overrideDuration,
                overrideTarget: overrideTarget,
                isTempTargetActive: isTempTargetActive,
                tempTargetName: tempTargetName,
                tempTargetDate: tempTargetDate,
                tempTargetDuration: tempTargetDuration,
                tempTargetTarget: tempTargetTarget,
                widgetItems: widgetItems,
                minForecast: keepForecasts ? minForecast : [],
                maxForecast: keepForecasts ? maxForecast : [],
                forecastLines: keepForecasts ? forecastLines : [],
                forecastDisplayType: forecastDisplayType
            )
        }
    }

    struct ChartItem: Codable, Hashable {
        let value: Decimal
        let date: Date
    }

    struct ForecastLine: Codable, Hashable {
        let type: String
        let values: [Int]
    }

    let startDate: Date
}

extension LiveActivityAttributes.ContentState {
    /// ActivityKit caps a Live Activity's content state at 4 KB of JSON. An oversized
    /// update is rejected with "Payload maximum size exceeded" and, because `update()`
    /// does not throw, the activity silently keeps whatever it last displayed — which
    /// for a freshly created activity is the `isInitialState` placeholder reading
    /// "Live Activity Expired". Stay below the cap with room for a longer override
    /// name or an extra reading rather than sailing up to it.
    static let maxPayloadBytes = 3600

    /// Size of this state as ActivityKit measures it.
    var encodedPayloadSize: Int {
        (try? JSONEncoder().encode(self))?.count ?? .max
    }

    /// Returns the most detailed version of this state that fits inside
    /// ``maxPayloadBytes``, shedding forecasts first and then thinning the glucose
    /// chart. The newest reading always survives.
    func fittedToPayloadLimit() -> Self {
        guard encodedPayloadSize > Self.maxPayloadBytes else { return self }

        // (chartStride, keepForecasts), progressively cheaper. Thin the glucose series
        // before giving up the forecast: dropping every other point costs far less
        // legibility on a chart this small than losing the prediction entirely.
        let fallbacks = [(2, true), (3, true), (3, false), (0, false)]
        for (chartStride, keepForecasts) in fallbacks {
            let candidate = replacingDetailedViewState(
                detailedViewState.shedding(chartStride: chartStride, keepForecasts: keepForecasts)
            )
            if candidate.encodedPayloadSize <= Self.maxPayloadBytes {
                return candidate
            }
        }

        // Nothing chart-related is left to drop; send it anyway so a size regression
        // elsewhere surfaces as ActivityKit's error rather than as silent staleness.
        return replacingDetailedViewState(detailedViewState.shedding(chartStride: 0, keepForecasts: false))
    }

    private func replacingDetailedViewState(_ newValue: LiveActivityAttributes.ContentAdditionalState) -> Self {
        LiveActivityAttributes.ContentState(
            unit: unit,
            bg: bg,
            direction: direction,
            change: change,
            date: date,
            highGlucose: highGlucose,
            lowGlucose: lowGlucose,
            target: target,
            glucoseColorScheme: glucoseColorScheme,
            useDetailedViewIOS: useDetailedViewIOS,
            useDetailedViewWatchOS: useDetailedViewWatchOS,
            detailedViewState: newValue,
            isInitialState: isInitialState
        )
    }
}
