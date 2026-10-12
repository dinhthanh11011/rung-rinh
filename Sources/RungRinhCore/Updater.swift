import Foundation

/// Dotted numeric version such as "v0.2.10" → [0, 2, 10]. Missing parts count as 0.
public struct Version: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Ignore pre-release / build suffixes: "1.2.0-beta" → "1.2.0".
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

public struct Release: Sendable, Equatable {
    public let tag: String
    public let notes: String
    public let url: URL?

    public var version: Version? { Version(tag) }
}

/// Checks GitHub releases and installs a newer one by re-running install.sh (the same path as a fresh install).
public struct Updater: Sendable {
    public static let repo = "dinhthanh11011/rung-rinh"
    public static let installScript = "https://raw.githubusercontent.com/\(repo)/main/install.sh"

    public init() {}

    /// Version of the running app bundle, or nil when running outside one (swift run).
    /// Resolves symlinks first: the CLI runs as ~/.local/bin/rungrinh → RungRinh.app/Contents/MacOS/rungrinh,
    /// and Bundle.main alone would look for an Info.plist next to the symlink.
    public static var currentVersion: Version? {
        guard let exe = Bundle.main.executablePath else { return nil }
        let plist = URL(fileURLWithPath: exe).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let text = info["CFBundleShortVersionString"] as? String else { return nil }
        return Version(text)
    }

    public func latestRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdaterError.http(http.statusCode)
        }
        return try Self.parse(data)
    }

    public static func parse(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            let tag_name: String
            let body: String?
            let html_url: String?
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        return Release(tag: p.tag_name, notes: p.body ?? "", url: p.html_url.flatMap(URL.init(string:)))
    }

    /// The newer release, or nil when up to date.
    public func availableUpdate(current: Version) async throws -> Release? {
        let latest = try await latestRelease()
        guard let v = latest.version, current < v else { return nil }
        return latest
    }

    /// `curl install.sh | RUNGRINH_VERSION=<tag> bash`, not yet started.
    public static func installProcess(tag: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "/usr/bin/curl -fsSL \"$1\" | RUNGRINH_VERSION=\"$2\" /bin/bash", "rungrinh-update", installScript, tag]
        return p
    }

    /// Runs install.sh for `tag` in a detached shell. install.sh quits the running app, replaces it and relaunches it,
    /// so the shell must outlive this process. Output goes to `log`. `onExit` only fires if we are still alive, i.e. it failed.
    public func install(tag: String, log: URL, onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let out = try FileHandle(forWritingTo: log)
        out.seekToEndOfFile()
        let p = Self.installProcess(tag: tag)
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { onExit($0.terminationStatus) }
        try p.run()
    }
}

public enum UpdaterError: Error, LocalizedError {
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "GitHub trả về HTTP \(code)"
        }
    }
}
