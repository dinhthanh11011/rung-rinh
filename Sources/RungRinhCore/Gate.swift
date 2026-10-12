import Foundation

public enum Event: Equatable, Sendable {
    /// Claude Code finished a turn. `duration` is nil when the start wasn't recorded.
    case claudeStop(duration: TimeInterval?)
    /// Claude Code is waiting for permission or input.
    case claudeNotification
    /// A command wrapped by `rungrinh run` / the shell integration finished.
    case command(duration: TimeInterval)
    /// `rungrinh notify` from a script / CI.
    case manual
    /// `rungrinh test` or the app's test button: always sent.
    case test

    public var source: String {
        switch self {
        case .claudeStop: return "claude.stop"
        case .claudeNotification: return "claude.notification"
        case .command: return "command"
        case .manual: return "notify"
        case .test: return "test"
        }
    }
}

public enum Decision: Equatable, Sendable {
    case send
    case skip(String)
}

public struct GateContext: Sendable {
    public var now: Date
    public var lastSentAt: Date?
    /// Seconds since the last keyboard/mouse input on this Mac.
    public var idleSeconds: @Sendable () -> TimeInterval

    public init(now: Date = Date(), lastSentAt: Date?, idleSeconds: @escaping @Sendable () -> TimeInterval) {
        self.now = now
        self.lastSentAt = lastSentAt
        self.idleSeconds = idleSeconds
    }
}

public enum Gate {
    public static func decide(_ event: Event, config: Config, context: GateContext) -> Decision {
        if event == .test { return .send }

        if !config.enabled { return .skip("disabled") }
        if config.isSnoozed(at: context.now) { return .skip("snoozed") }
        if config.quietHours.contains(context.now) { return .skip("quiet hours") }

        switch event {
        case .claudeStop(let duration):
            if !config.events.stop { return .skip("stop event off") }
            guard let duration else { return .skip("unknown duration") }
            let secs = Int(duration.rounded())
            if secs < config.minTaskSeconds {
                return .skip("too short (\(secs)s < \(config.minTaskSeconds)s)")
            }
        case .command(let duration):
            let secs = Int(duration.rounded())
            if secs < config.minTaskSeconds {
                return .skip("too short (\(secs)s < \(config.minTaskSeconds)s)")
            }
        case .claudeNotification:
            if !config.events.notification { return .skip("notification event off") }
        case .manual, .test:
            // Explicit pushes skip the idle and cooldown rules.
            return .send
        }

        if config.onlyWhenIdle {
            let idle = context.idleSeconds()
            if Int(idle) < config.idleSeconds {
                return .skip("user at Mac (idle \(Int(idle))s < \(config.idleSeconds)s)")
            }
        }

        if let last = context.lastSentAt {
            let gap = context.now.timeIntervalSince(last)
            if gap >= 0, Int(gap) < config.cooldownSeconds {
                return .skip("cooldown (\(Int(gap))s < \(config.cooldownSeconds)s)")
            }
        }
        return .send
    }
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
    return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m"
}
