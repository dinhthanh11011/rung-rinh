import Foundation

public enum Snooze {
    /// Parses "30m", "1h", "90s", "2d", "1h30m" or "morning" (next 08:00) into an end date.
    public static func until(_ spec: String, from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let s = spec.lowercased().trimmingCharacters(in: .whitespaces)
        if s == "morning" || s == "tomorrow" { return nextMorning(after: now, calendar: calendar) }

        var total: TimeInterval = 0
        var number = ""
        for ch in s {
            if ch.isNumber {
                number.append(ch)
                continue
            }
            guard let n = Double(number) else { return nil }
            switch ch {
            case "s": total += n
            case "m": total += n * 60
            case "h": total += n * 3600
            case "d": total += n * 86400
            default: return nil
            }
            number = ""
        }
        if let n = Double(number) { total += n * 60 } // bare number = minutes
        return total > 0 ? now.addingTimeInterval(total) : nil
    }

    public static func nextMorning(after now: Date, hour: Int = 8, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)!
    }
}
