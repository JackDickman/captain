import SwiftUI

/// Three-day forecast strip on the home screen. Three equal columns —
/// today + tomorrow + the day after — each with a brass icon, temperature,
/// and short condition. Quiet card with brass border, matching the MCM
/// register of the rest of the home view.
struct WeatherWidget: View {
    let periods: [WeatherPeriod]

    /// Pick the first three daytime periods. NWS alternates day/night, so
    /// this naturally yields today + tomorrow + day-after when called
    /// during the day. If called at night, it still returns the next three
    /// daytime periods (i.e. starting with tomorrow).
    private var days: [WeatherPeriod] {
        Array(periods.filter { $0.isDaytime }.prefix(3))
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { idx, period in
                if idx > 0 {
                    // Fixed-height divider so it doesn't stretch the row.
                    Rectangle()
                        .fill(CaptainTheme.brass.opacity(0.25))
                        .frame(width: 1, height: 22)
                }
                dayColumn(period: period, index: idx)
                    .frame(maxWidth: .infinity)
            }
            if days.isEmpty {
                Text("weather unavailable")
                    .font(CaptainTheme.body(12))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CaptainTheme.creamDeep.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.35),
                            lineWidth: 1
                        )
                )
        )
    }

    /// Compact one-row column: day label · icon · temp. Condition text is
    /// intentionally omitted — the icon carries it, and the row needs to
    /// stay visually quiet against the rendered home above.
    @ViewBuilder
    private func dayColumn(period: WeatherPeriod, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(label(for: period, index: index))
                .font(CaptainTheme.label(10))
                .foregroundStyle(CaptainTheme.textMuted)
                .tracking(1.0)
                .textCase(.uppercase)
                .lineLimit(1)
            Image(systemName: iconName(for: period.short))
                .font(.system(size: 15))
                .foregroundStyle(CaptainTheme.brass)
            Text("\(period.temperature ?? 0)°")
                .font(CaptainTheme.display(15))
                .foregroundStyle(CaptainTheme.textPrimary)
        }
        .padding(.horizontal, 4)
    }

    /// Label per column: TODAY / TOMORROW / weekday-abbreviation.
    /// NWS sometimes labels day-3 with holiday names ("Memorial Day") —
    /// fall back to those when we can't extract a weekday.
    private func label(for period: WeatherPeriod, index: Int) -> String {
        switch index {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let weekdays = [
                "Monday", "Tuesday", "Wednesday", "Thursday",
                "Friday", "Saturday", "Sunday",
            ]
            for day in weekdays {
                if period.name.contains(day) {
                    return String(day.prefix(3))
                }
            }
            return period.name
        }
    }

    /// Map NWS short-forecast strings to SF Symbols.
    private func iconName(for condition: String) -> String {
        let c = condition.lowercased()
        if c.contains("thunder") { return "cloud.bolt.rain.fill" }
        if c.contains("snow") || c.contains("sleet") { return "cloud.snow.fill" }
        if c.contains("rain") || c.contains("shower") || c.contains("drizzle") {
            return "cloud.rain.fill"
        }
        if c.contains("fog") || c.contains("mist") || c.contains("haze") {
            return "cloud.fog.fill"
        }
        if c.contains("partly") && (c.contains("cloud") || c.contains("sunny")) {
            return "cloud.sun.fill"
        }
        if c.contains("mostly cloudy") { return "cloud.fill" }
        if c.contains("cloud") { return "cloud.fill" }
        if c.contains("clear") || c.contains("sunny") || c.contains("fair") {
            return "sun.max.fill"
        }
        if c.contains("wind") { return "wind" }
        return "sun.max.fill"
    }
}

#Preview {
    VStack {
        WeatherWidget(periods: [
            WeatherPeriod(name: "This Afternoon", temperature: 71,
                          unit: "F", short: "Partly Cloudy", isDaytime: true),
            WeatherPeriod(name: "Tonight", temperature: 58,
                          unit: "F", short: "Chance Rain Showers",
                          isDaytime: false),
            WeatherPeriod(name: "Memorial Day", temperature: 71,
                          unit: "F", short: "Areas Of Fog then Partly Sunny",
                          isDaytime: true),
            WeatherPeriod(name: "Monday Night", temperature: 54,
                          unit: "F", short: "Mostly Cloudy", isDaytime: false),
            WeatherPeriod(name: "Tuesday", temperature: 80,
                          unit: "F", short: "Mostly Sunny", isDaytime: true),
        ])
        WeatherWidget(periods: [])
    }
    .padding()
    .background(CaptainTheme.cream)
}
