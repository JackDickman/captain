import Foundation

/// One forecast period from NWS, surfaced via /weather. Periods alternate
/// daytime / overnight (e.g. "This Afternoon" / "Tonight" / "Tomorrow").
struct WeatherPeriod: Codable, Equatable, Identifiable, Hashable {
    let name: String
    let temperature: Int?
    let unit: String
    let short: String
    let isDaytime: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, temperature, unit, short
        case isDaytime
    }
}

struct WeatherResponse: Codable {
    let periods: [WeatherPeriod]
}
