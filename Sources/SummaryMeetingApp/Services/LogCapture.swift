import Foundation
import Darwin

/// 启动时把 stderr / stdout 同时落盘到 ~/Library/Logs/AIMA/aima-<yyyyMMdd>.log，
/// 终端依然能看到（开发联调），公证包（无终端）的输出会写进文件。
/// 用户在权限页或菜单里"在 Finder 中显示日志"即可把文件发给我们排查。
public enum LogCapture {
    /// 当前会话日志文件路径
    public static private(set) var currentLogURL: URL?

    /// 日志根目录：~/Library/Logs/AIMA
    public static var logsDir: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AIMA")
    }

    /// App 启动时调用一次。失败不影响主流程。
    public static func install() {
        let dir = logsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let logURL = dir.appendingPathComponent("aima-\(f.string(from: Date())).log")
        currentLogURL = logURL

        // 头部信息：版本、设备
        let bundle = Bundle.main.infoDictionary
        let version = bundle?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = bundle?["CFBundleVersion"] as? String ?? "?"
        var sysname = utsname()
        uname(&sysname)
        let machine = withUnsafePointer(to: &sysname.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let release = withUnsafePointer(to: &sysname.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let header = """
        ─── AIMA log start ────────────────────────────────────────
        version : \(version) (build \(build))
        machine : \(machine)
        kernel  : \(release)
        time    : \(Date())
        pid     : \(getpid())
        log path: \(logURL.path)
        ───────────────────────────────────────────────────────────

        """
        try? header.data(using: .utf8)?.write(to: logURL, options: .atomic)

        // 用 fopen("a") 追加模式打开，再用 dup2 重定向 fd 2/1。
        // 终端模式下原 stderr 仍然会被写入日志文件（dup2 不保留旧 fd）；
        // 想保留双写需要复杂的 pipe + 旁路线程，公证包没终端无所谓，简单点足够。
        guard let fp = fopen(logURL.path, "a") else { return }
        let fd = fileno(fp)
        dup2(fd, fileno(stderr))
        dup2(fd, fileno(stdout))
        fclose(fp)

        // 立刻 line-buffered，避免日志延迟落盘
        setvbuf(stderr, nil, _IOLBF, 0)
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    /// 在 Finder 中显示日志目录
    public static func revealLogsInFinder() {
        let dir = logsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 用 open 命令打开，避免 GUI 进程额外的 NSWorkspace 调用
        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [dir.path])
    }

    /// 用默认应用打开当前日志文件
    public static func openCurrentLog() {
        guard let url = currentLogURL else {
            revealLogsInFinder()
            return
        }
        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [url.path])
    }
}
