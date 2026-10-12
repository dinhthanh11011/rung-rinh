import CoreGraphics
import Darwin
import Foundation

/// The terminal / editor window Claude Code runs in, approximated by the app process that owns it.
public enum HostApp {
    /// This process and its ancestors, nearest first. The hook runs under Claude Code, which runs
    /// under a shell in Terminal / iTerm / VS Code…, so the host app is somewhere in this chain.
    public static func ancestorPids() -> [Int32] {
        var out: [Int32] = []
        var pid = getpid()
        while pid > 1, out.count < 64 {
            out.append(pid)
            guard let parent = parentPid(of: pid), parent != pid else { break }
            pid = parent
        }
        return out
    }

    static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Owner of the frontmost normal window. Owner pids don't need Screen Recording permission
    /// (only window titles do), and this reads fresh state even in a long-sleeping process.
    public static func frontmostPid() -> Int32? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? Int32 { return pid }
            if let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value { return pid }
        }
        return nil
    }
}

/// Whether the user is looking at the window Claude runs in: its app is in front and they've
/// touched the keyboard / mouse within `window` seconds. Pushing then would tell them nothing.
public struct Presence: Sendable {
    public let frontmostPid: @Sendable () -> Int32?
    public let idleSeconds: @Sendable () -> TimeInterval

    public init(
        frontmostPid: @escaping @Sendable () -> Int32? = { HostApp.frontmostPid() },
        idleSeconds: @escaping @Sendable () -> TimeInterval = { IdleTime.seconds() }
    ) {
        self.frontmostPid = frontmostPid
        self.idleSeconds = idleSeconds
    }

    public func isActive(in hostPids: [Int32], within window: TimeInterval) -> Bool {
        guard !hostPids.isEmpty, let front = frontmostPid(), hostPids.contains(front) else { return false }
        return idleSeconds() < window
    }
}
