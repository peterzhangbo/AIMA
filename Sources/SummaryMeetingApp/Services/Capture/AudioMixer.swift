import Foundation

public enum AudioMixer {
    /// 将 mic wav 与 system wav 混音为单一 wav；任一轨缺失时退化为拷贝存在的那一轨。
    public static func mix(mic: URL?, system: URL?, output: URL, logTo: URL? = nil) throws {
        let fm = FileManager.default
        let micExists = mic.map { fm.fileExists(atPath: $0.path) } ?? false
        let sysExists = system.map { fm.fileExists(atPath: $0.path) } ?? false

        if FileManager.default.fileExists(atPath: output.path) {
            try? fm.removeItem(at: output)
        }

        if micExists && sysExists {
            let result = try ProcessRunner.run(
                executable: "ffmpeg",
                arguments: [
                    "-y",
                    "-i", mic!.path,
                    "-i", system!.path,
                    "-filter_complex", "[0:a]aresample=48000[a0];[1:a]aresample=48000,pan=mono|c0=0.5*c0+0.5*c1[a1];[a0][a1]amix=inputs=2:duration=longest:normalize=0[aout]",
                    "-map", "[aout]",
                    "-ac", "1",
                    "-ar", "48000",
                    "-c:a", "pcm_s16le",
                    output.path
                ],
                logTo: logTo
            )
            if !result.succeeded {
                throw ProcessRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
            }
        } else if let single = (micExists ? mic : (sysExists ? system : nil)) {
            let result = try ProcessRunner.run(
                executable: "ffmpeg",
                arguments: [
                    "-y", "-i", single.path,
                    "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le",
                    output.path
                ],
                logTo: logTo
            )
            if !result.succeeded {
                throw ProcessRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
            }
        } else {
            throw NSError(domain: "AudioMixer", code: 1, userInfo: [NSLocalizedDescriptionKey: "麦克风和系统音频均缺失"])
        }
    }
}
