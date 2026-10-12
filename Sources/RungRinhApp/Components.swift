import RungRinhCore
import SwiftUI

/// Spacing scale for the popover; use these instead of ad-hoc numbers.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
}

/// Dot + text, so state is never conveyed by color alone.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inline result of an action: spinner while running, then a success / error line.
struct NoticeView: View {
    let notice: Notice?

    var body: some View {
        if let notice {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch notice.kind {
                case .progress: ProgressView().controlSize(.mini)
                case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .info: Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
                }
                Text(notice.text)
                    .font(.caption)
                    .foregroundStyle(notice.kind == .error ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .transition(.opacity)
        }
    }
}

struct SecondsStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(formatDuration(TimeInterval(value))).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

struct HourPicker: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        Picker(title, selection: Binding(get: { minutes / 60 }, set: { minutes = $0 * 60 })) {
            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
        }
    }
}

/// Centered icon + message + optional action for empty lists.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium))
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.run).padding(.top, Spacing.xs)
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Section footer: grouped forms center/trail it by default, which reads badly for sentences.
struct FormFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
