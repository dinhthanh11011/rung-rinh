import Foundation

public struct DispatchResult: Equatable, Sendable {
    public var decision: Decision
    public var error: String?

    public var sent: Bool { decision == .send && error == nil }
}

/// Gate -> notifier -> history. Shared by the CLI, the Claude hook and the app.
public struct Dispatcher: Sendable {
    public let paths: Paths
    public let idleSeconds: @Sendable () -> TimeInterval
    public let makeNotifier: @Sendable (Config) throws -> Notifier

    public init(
        paths: Paths = Paths(),
        idleSeconds: @escaping @Sendable () -> TimeInterval = { IdleTime.seconds() },
        makeNotifier: @escaping @Sendable (Config) throws -> Notifier = { try Notifiers.make(for: $0) }
    ) {
        self.paths = paths
        self.idleSeconds = idleSeconds
        self.makeNotifier = makeNotifier
    }

    @discardableResult
    public func dispatch(_ event: Event, _ message: Message, config: Config? = nil) async -> DispatchResult {
        let config = config ?? ConfigStore(paths: paths).load()
        let state = StateStore(paths: paths)
        let history = History(paths: paths)
        let context = GateContext(lastSentAt: state.lastSentAt, idleSeconds: idleSeconds)

        let decision = Gate.decide(event, config: config, context: context)
        guard decision == .send else {
            if case .skip(let reason) = decision {
                history.append(HistoryEntry(source: event.source, title: message.title, sent: false, detail: reason))
            }
            return DispatchResult(decision: decision)
        }

        do {
            try await makeNotifier(config).send(message)
            state.markSent()
            history.append(HistoryEntry(source: event.source, title: message.title, sent: true))
            return DispatchResult(decision: .send)
        } catch {
            let text = error.localizedDescription
            history.append(HistoryEntry(source: event.source, title: message.title, sent: false, detail: "error: \(text)"))
            Log(paths: paths).write("[\(event.source)] send failed: \(text)")
            return DispatchResult(decision: .send, error: text)
        }
    }
}
