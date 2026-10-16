import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case bark, ntfy
}

public struct BarkConfig: Codable, Equatable, Sendable {
    public var server = "https://api.day.app"
    public var key = ""
    public var sound = ""
    /// active | timeSensitive | passive | critical
    public var level = "timeSensitive"
    public var group = "RungRinh"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BarkConfig()
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? d.server
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? d.key
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? d.sound
        level = try c.decodeIfPresent(String.self, forKey: .level) ?? d.level
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? d.group
    }
}

public struct NtfyConfig: Codable, Equatable, Sendable {
    public var server = "https://ntfy.sh"
    public var topic = ""
    public var token = ""
    /// 1 (min) ... 5 (max)
    public var priority = 4

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NtfyConfig()
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? d.server
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? d.topic
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? d.token
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? d.priority
    }
}

/// Quiet hours as minutes since midnight, e.g. 22:00 -> 1320. Wraps past midnight when start > end.
public struct QuietHours: Codable, Equatable, Sendable {
    public var enabled = false
    public var start = 22 * 60
    public var end = 7 * 60

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuietHours()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? d.start
        end = try c.decodeIfPresent(Int.self, forKey: .end) ?? d.end
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, start != end else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let m = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }
}

public struct EventToggles: Codable, Equatable, Sendable {
    /// Claude Code finished a task.
    public var stop = true
    /// Claude Code is waiting for permission / input.
    public var notification = true
    /// Claude Code stopped on an API error (login, usage limit, overload…).
    public var error = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stop = try c.decodeIfPresent(Bool.self, forKey: .stop) ?? true
        notification = try c.decodeIfPresent(Bool.self, forKey: .notification) ?? true
        error = try c.decodeIfPresent(Bool.self, forKey: .error) ?? true
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var enabled = true
    public var snoozeUntil: Date?
    public var provider = Provider.bark
    public var bark = BarkConfig()
    public var ntfy = NtfyConfig()
    /// Claude tasks / wrapped commands shorter than this don't push.
    public var minTaskSeconds = 120
    /// Minimum gap between two pushes.
    public var cooldownSeconds = 30
    /// A finished task pushes only if, this long after it ends, the user hasn't sent another prompt
    /// and isn't using the window Claude runs in (0 = push right away).
    public var doneDelaySeconds = 60
    /// Only push when the Mac has had no keyboard/mouse input for `idleSeconds`.
    public var onlyWhenIdle = false
    public var idleSeconds = 120
    public var quietHours = QuietHours()
    public var events = EventToggles()
    /// Claude asked a question / wants permission: push only if it is still unanswered after this long.
    public var askDelaySeconds = 300
    /// One more push if it is still unanswered this long after the first one (0 = never).
    public var askReminderSeconds = 600
    /// The menu bar app installs new GitHub releases by itself.
    public var autoUpdate = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        snoozeUntil = try c.decodeIfPresent(Date.self, forKey: .snoozeUntil)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? d.provider
        bark = try c.decodeIfPresent(BarkConfig.self, forKey: .bark) ?? d.bark
        ntfy = try c.decodeIfPresent(NtfyConfig.self, forKey: .ntfy) ?? d.ntfy
        minTaskSeconds = try c.decodeIfPresent(Int.self, forKey: .minTaskSeconds) ?? d.minTaskSeconds
        cooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? d.cooldownSeconds
        doneDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .doneDelaySeconds) ?? d.doneDelaySeconds
        onlyWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .onlyWhenIdle) ?? d.onlyWhenIdle
        idleSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? d.idleSeconds
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? d.quietHours
        events = try c.decodeIfPresent(EventToggles.self, forKey: .events) ?? d.events
        askDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .askDelaySeconds) ?? d.askDelaySeconds
        askReminderSeconds = try c.decodeIfPresent(Int.self, forKey: .askReminderSeconds) ?? d.askReminderSeconds
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? d.autoUpdate
    }

    public var isConfigured: Bool {
        switch provider {
        case .bark: return !bark.key.trimmingCharacters(in: .whitespaces).isEmpty
        case .ntfy: return !ntfy.topic.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    public func isSnoozed(at now: Date = Date()) -> Bool {
        guard let until = snoozeUntil else { return false }
        return now < until
    }
}
