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
    /// 用户登录 shell（~/.zshrc / ~/.zprofile）里 export 的实际 PATH。
    /// `captureUserShellPath()` 在 App 启动时跑一次抓到。GUI 启动的 .app 默认
    /// 只有最小 PATH（/usr/bin:/bin:/usr/sbin:/sbin），抓不到 ffmpeg/python3
    /// 等装在 Homebrew/MacPorts/conda/pyenv/asdf 路径下的工具——这里补全。
    public static var userShellPath: String?

    /// 启动时调用一次。失败不影响主流程，augmentedPath 还有静态兜底。
    public static func captureUserShellPath() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-ilc", "echo $PATH"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let s = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return }
            userShellPath = s
            FileHandle.standardError.write(Data("[ProcessRunner] user shell PATH captured: \(s)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[ProcessRunner] failed to capture user shell PATH: \(error)\n".utf8))
        }
    }

    /// 给子进程喂的 PATH。优先级：用户登录 shell PATH（如果抓到了）→ 静态兜底列表。
    /// 静态列表覆盖：python.org framework、Homebrew、MacPorts、conda/pyenv/asdf/mise
    /// shims、~/.local/bin、~/Library/Python/*/bin。
    public static var augmentedPath: String {
        var parts: [String] = [
            "/Library/Frameworks/Python.framework/Versions/3.13/bin",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",        // MacPorts
            "/usr/bin", "/bin"
        ]
        let home = NSString("~").expandingTildeInPath
        parts.append(contentsOf: [
            "\(home)/.local/bin",
            "\(home)/.pyenv/shims",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/miniconda3/bin",
            "\(home)/anaconda3/bin",
            "\(home)/mambaforge/bin",
            "\(home)/miniforge3/bin"
        ])
        // ~/Library/Python/<version>/bin glob——pip3 install --user 装 CLI 的位置
        let userPyRoot = "\(home)/Library/Python"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: userPyRoot) {
            for entry in entries {
                parts.append("\(userPyRoot)/\(entry)/bin")
            }
        }
        var result = parts.joined(separator: ":")
        if let userPath = userShellPath, !userPath.isEmpty {
            result = userPath + ":" + result
        }
        return result
    }

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
