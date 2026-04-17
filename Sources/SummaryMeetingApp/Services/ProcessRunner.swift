import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "进程启动失败: \(m)"
        case .nonZeroExit(let c, let s): return "进程退出码 \(c): \(s)"
        }
    }
}

public enum ProcessRunner {
    /// Extra PATH entries to prepend so Python tools and homebrew binaries resolve from a GUI app.
    public static let augmentedPath: String = [
        "/Library/Frameworks/Python.framework/Versions/3.13/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ].joined(separator: ":")

    @discardableResult
    public static func run(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        logTo logURL: URL? = nil
    ) throws -> ProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if process.arguments == nil {
            process.arguments = arguments
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPath + ":" + (env["PATH"] ?? "")
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if let logURL = logURL {
            let header = "\n$ \(executable) \(arguments.joined(separator: " "))\n"
            let body = "--- stdout ---\n\(stdout)\n--- stderr ---\n\(stderr)\n"
            try? (header + body).appending("\n").write(to: logURL, atomically: false, encoding: .utf8)
        }

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
