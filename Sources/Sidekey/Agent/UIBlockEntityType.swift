import Foundation

enum UIBlockEntityType: String, Codable, Equatable {
    case calendarEvent = "calendar_event"
    case systemSetting = "system_setting"
    case weather
    case file
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = UIBlockEntityType(rawValue: rawValue) ?? .unknown
    }
}
