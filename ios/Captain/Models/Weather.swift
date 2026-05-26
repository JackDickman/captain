import Foundation

/// One forecast period from NWS, surfaced via /weather. Periods alternate
/// daytime / overnight (e.g. "This Afternoon" / "Tonight" / "Tomorrow").
struct WeatherPeriod: Codable, Equatable, Identifiable, Hashable {
    let name: String
    let temperature: Int?
    let unit: String
    let short: String
    let isDaytime: Bool
    /// 0–100, or nil when the forecaster didn't quantify precip for the
    /// period. The WeatherWidget hides the precip line when nil.
    let precipChance: Int?

    /// Composite id — NWS period names are usually unique within one
    /// response, but combining with daytime + temp guards against the
    /// rare collision (and against custom periods we might inject later).
    var id: String { "\(name)|\(isDaytime ? "d" : "n")|\(temperature ?? -999)" }

    enum CodingKeys: String, CodingKey {
        case name, temperature, unit, short
        case isDaytime
        case precipChance
    }
}

struct WeatherResponse: Codable {
    let periods: [WeatherPeriod]
}
