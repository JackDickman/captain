import SwiftUI

/// Three-day forecast card on the home screen.
///
/// Each column is a small stack:
///   • Day label    (TODAY / TOMORROW / THU)
///   • Big weather icon
///   • Temperature  · precip%
///
/// Precip is included alongside temperature because yard / exterior decisions
/// hinge on it as much as on heat. Hidden when NWS didn't quantify it.
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
            if days.isEmpty {
                Text("weather unavailable")
                    .font(CaptainTheme.body(12))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(days.enumerated()), id: \.element.id) { idx, period in
                    if idx > 0 {
                        Rectangle()
                            .fill(CaptainTheme.brass.opacity(0.25))
                            .frame(width: 1)
                            .padding(.vertical, 12)
                    }
                    dayColumn(period: period, index: idx)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        // Defensive maxWidth so the widget always fills its row inside
        // the home-screen leading-aligned content VStack — without it,
        // dayColumns might not propose enough width to stretch the HStack.
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(CaptainTheme.creamDeep.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.35),
                            lineWidth: 1
                        )
                )
        )
    }

    /// Column: day label on top, icon centered, then temp + precip on the
    /// bottom row. Vertically padded so the contents breathe inside the
    /// taller card.
    @ViewBuilder
    private func dayColumn(period: WeatherPeriod, index: Int) -> some View {
        VStack(spacing: 6) {
            Text(label(for: period, index: index))
                .font(CaptainTheme.label(10))
                .foregroundStyle(CaptainTheme.textMuted)
                .tracking(1.0)
                .textCase(.uppercase)
                .lineLimit(1)
            Image(systemName: iconName(for: period.short))
                .font(.system(size: 22))
                .foregroundStyle(CaptainTheme.brass)
            HStack(spacing: 8) {
                Text("\(period.temperature ?? 0)°")
                    .font(CaptainTheme.display(16))
                    .foregroundStyle(CaptainTheme.textPrimary)
                if let chance = period.precipChance, chance > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(precipColor(chance))
                        Text("\(chance)%")
                            .font(CaptainTheme.body(11, weight: .medium))
                            .foregroundStyle(precipColor(chance))
                    }
                }
            }
        }
        .padding(.vertical, 10)
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

    /// Brass for low-chance precip (≤20% — a polite footnote), muted blue
    /// for medium (a real possibility), rust for high (plan around it).
    private func precipColor(_ chance: Int) -> Color {
        if chance >= 60 { return CaptainTheme.rust }
        if chance >= 30 { return CaptainTheme.walnut }
        return CaptainTheme.textMuted
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
                          unit: "F", short: "Partly Cloudy", isDaytime: true,
                          precipChance: 10),
            WeatherPeriod(name: "Tonight", temperature: 58,
                          unit: "F", short: "Chance Rain Showers",
                          isDaytime: false, precipChance: 70),
            WeatherPeriod(name: "Memorial Day", temperature: 71,
                          unit: "F", short: "Areas Of Fog then Partly Sunny",
                          isDaytime: true, precipChance: 40),
            WeatherPeriod(name: "Monday Night", temperature: 54,
                          unit: "F", short: "Mostly Cloudy", isDaytime: false,
                          precipChance: 30),
            WeatherPeriod(name: "Tuesday", temperature: 80,
                          unit: "F", short: "Mostly Sunny", isDaytime: true,
                          precipChance: 0),
        ])
        WeatherWidget(periods: [])
    }
    .padding()
    .background(CaptainTheme.cream)
}
