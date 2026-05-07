import SwiftUI
import AVFoundation
import Darwin
import AppKit

// MARK: - PermissionsModel

@MainActor
@Observable
final class PermissionsModel {

    // MARK: System permissions

    var micGranted: Bool = MicRecorder.isAuthorized
    var screenGranted: Bool = false
    var checking: Bool = false

    // MARK: Env deps

    struct DepResult: Equatable {
        var state: State = .pending
        /// 解析到的可执行文件绝对路径（state==.ok 时）；UI 显示用于诊断
        var resolvedPath: String? = nil
        enum State: Equatable { case pending, ok, missing }
    }

    var brew        = DepResult()
    var python3     = DepResult()
    var ffmpeg      = DepResult()
    var hfCli       = DepResult()
    var mlxWhisper  = DepResult()
    var mlxVlm      = DepResult()
    var pyannote    = DepResult()   // optional
    var checkingDeps = false

    // MARK: AI 模型缓存
    var whisperModel  = DepResult()
    var gemmaModel    = DepResult()
    var pyannoteModel = DepResult()   // optional

    var allGranted: Bool { micGranted && screenGranted }

    var checksDone: Bool {
        !checking && !checkingDeps && python3.state != .pending
    }

    /// brew 仅当 python3/ffmpeg 尚未就绪时才是必备条件。
    var brewEffectivelyRequired: Bool {
        python3.state != .ok || ffmpeg.state != .ok
    }

    /// hf-cli 仅当必需模型尚未下载时才是必备条件。
    var hfCliEffectivelyRequired: Bool {
        whisperModel.state != .ok || gemmaModel.state != .ok
    }

    var requiredDepsOK: Bool {
        python3.state == .ok && ffmpeg.state == .ok
            && mlxWhisper.state == .ok && mlxVlm.state == .ok
            && (!brewEffectivelyRequired || brew.state == .ok)
            && (!hfCliEffectivelyRequired || hfCli.state == .ok)
    }

    // MARK: Hardware profile

    struct Hardware: Equatable {
        let chip: String        // e.g. "Apple M3 Pro" / "Intel x86_64"
        let ramGB: Double
        let isAppleSilicon: Bool

        enum Tier: String { case low, mid, high }
        var tier: Tier {
            if ramGB >= 32 { return .high }
            if ramGB >= 16 { return .mid }
            return .low
        }
        var tierLabel: String {
            switch tier {
            case .low:  return "入门（<16GB）"
            case .mid:  return "标准（16-32GB）"
            case .high: return "高配（≥32GB）"
            }
        }
    }

    let hardware: Hardware = PermissionsModel.detectHardware()

    private static func detectHardware() -> Hardware {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(bytes) / 1_073_741_824
        let isArm = sysctlString("hw.machine") == "arm64"
        var chip = sysctlString("machdep.cpu.brand_string")
        if chip.isEmpty {
            chip = isArm ? "Apple Silicon" : "Intel"
        }
        return Hardware(chip: chip, ramGB: ramGB, isAppleSilicon: isArm)
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    // MARK: Model recommendations

    struct ModelSpec {
        let id: String
        let size: String
        let note: String
    }

    /// 按硬件档位推荐的模型（不直接改运行时配置，仅显示提示）
    var recommendedWhisper: ModelSpec {
        switch hardware.tier {
        case .low:  return .init(id: "mlx-community/whisper-base-mlx",         size: "~150MB", note: "速度快，精度较低")
        case .mid:  return .init(id: "mlx-community/whisper-large-v3-turbo",   size: "~1.5GB", note: "当前默认，推荐")
        case .high: return .init(id: "mlx-community/whisper-large-v3-turbo",   size: "~1.5GB", note: "当前默认；追求极致精度可换 whisper-large-v3")
        }
    }
    var recommendedGemma: ModelSpec {
        switch hardware.tier {
        case .low:  return .init(id: "mlx-community/gemma-4-e4b-it-4bit",     size: "~3GB",     note: "Gemma 4 Any-to-Any 轻量版（~8B 总），小内存可用")
        case .mid:  return .init(id: "mlx-community/gemma-4-26b-a4b-it-4bit", size: "~15-18GB", note: "当前默认；MoE 架构，26B 总 / 4B 激活，速度接近 4B、质量接近稠密 26B")
        case .high: return .init(id: "mlx-community/gemma-4-31b-it-4bit",     size: "~18-22GB", note: "Gemma 4 稠密 31B，质量最佳（需 ≥32GB 统一内存）")
        }
    }
    /// 当前运行时使用的模型 id（和 Runner 中的常量对应）
    let currentWhisperID = "mlx-community/whisper-large-v3-turbo"
    let currentGemmaID   = "mlx-community/gemma-4-26b-a4b-it-4bit"
    let currentPyannoteID = "pyannote/speaker-diarization-community-1"

    // MARK: Actions

    func requestMic() async {
        micGranted = await MicRecorder.requestPermission()
    }

    func probeScreen() async {
        checking = true
        defer { checking = false }
        screenGranted = await SystemAudioRecorder.requestPermissionPrompt()
    }

    func checkDeps() async {
        checkingDeps = true
        defer { checkingDeps = false }

        // 依赖工具：先并行解析二进制（含路径），再用解析到的 python3 跑 pythonImport，
        // 这样即便对方 python3 在 pyenv/conda/asdf 的 shims，import 检测也能命中正确的解释器。
        async let rBrew  = shellCheckWithPath(names: ["brew"], args: ["--version"])
        async let r0     = shellCheckWithPath(names: ["python3", "python"], args: ["--version"])
        async let r1     = shellCheckWithPath(names: ["ffmpeg"], args: ["-version"])
        // huggingface_hub 0.32+ 把 huggingface-cli 重命名为 hf，两者都接受
        async let rHf    = shellCheckWithPath(names: ["huggingface-cli", "hf"], args: ["--help"])

        let (vBrew, v0, v1, vHf) = await (rBrew, r0, r1, rHf)

        // python import 使用解析到的 python3 绝对路径（pyenv/conda 路径下 bare 名找不到时关键）
        let pyExe = v0.path ?? "python3"
        async let r2 = pythonImport("mlx_whisper",   python: pyExe)
        async let r3 = pythonImport("mlx_vlm",       python: pyExe)
        async let r4 = pythonImport("pyannote.audio", python: pyExe)

        // 模型缓存（文件系统扫描，快）
        async let m0 = Self.modelCached(currentWhisperID)
        async let m1 = Self.modelCached(currentGemmaID)
        async let m2 = Self.modelCached(currentPyannoteID)

        let (v2, v3, v4) = await (r2, r3, r4)
        let (w, g, p) = await (m0, m1, m2)
        brew       = resolved(name: "brew",            ok: vBrew.ok, path: vBrew.path)
        python3    = resolved(name: "python3",         ok: v0.ok,    path: v0.path)
        ffmpeg     = resolved(name: "ffmpeg",          ok: v1.ok,    path: v1.path)
        hfCli      = resolved(name: "huggingface-cli", ok: vHf.ok,   path: vHf.path)
        mlxWhisper = resolved(name: "mlx_whisper",     ok: v2)
        mlxVlm     = resolved(name: "mlx_vlm",         ok: v3)
        pyannote   = resolved(name: "pyannote.audio",  ok: v4)
        whisperModel  = resolved(name: "whisper_model",  ok: w)
        gemmaModel    = resolved(name: "gemma_model",    ok: g)
        pyannoteModel = resolved(name: "pyannote_model", ok: p)
    }

    /// DEBUG 构建下支持通过 `SM_FAKE_MISSING=ffmpeg,mlx_whisper,whisper_model,all` 伪造缺失。
    private func resolved(name: String, ok: Bool, path: String? = nil) -> DepResult {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SM_FAKE_MISSING"], !raw.isEmpty {
            let set = Set(raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            })
            if set.contains("all") || set.contains(name.lowercased()) {
                return .init(state: .missing, resolvedPath: nil)
            }
        }
        #endif
        return .init(state: ok ? .ok : .missing, resolvedPath: ok ? path : nil)
    }

    /// 扫描 HuggingFace 缓存：~/.cache/huggingface/hub/models--{org}--{name}/snapshots/*
    private static func modelCached(_ hfId: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let folder = "models--" + hfId.replacingOccurrences(of: "/", with: "--")
            let snapshots = home.appendingPathComponent(".cache/huggingface/hub/\(folder)/snapshots")
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path),
                  !entries.isEmpty else { return false }
            for e in entries {
                let inside = snapshots.appendingPathComponent(e)
                if let files = try? FileManager.default.contentsOfDirectory(atPath: inside.path),
                   !files.isEmpty { return true }
            }
            return false
        }.value
    }

    // MARK: Private helpers

    /// 尝试从一组候选名解析出可用二进制的绝对路径，并跑 `args` 验证可调用。
    /// 三层兜底覆盖 Homebrew / MacPorts / pyenv / conda / asdf / mise / ~/.local/bin 等常见安装位置，
    /// 最后还会用 `/bin/zsh -ilc 'command -v ...'` 加载用户自己的 shell rc 当兜底。
    private func shellCheckWithPath(names: [String], args: [String]) async -> (ok: Bool, path: String?) {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            // 1) 裸名走 ProcessRunner.augmentedPath（Python framework + Homebrew）
            for name in names {
                if (try? ProcessRunner.run(executable: name, arguments: args))?.succeeded == true {
                    // 裸名命中时拿不到绝对路径，但能确认可用——继续往下解析路径，路径解析失败也不影响 ok=true
                    if let resolved = Self.resolveExecutablePath(names: [name]) {
                        return (true, resolved)
                    }
                    return (true, nil)
                }
            }
            // 2) 直接查扩展兜底路径
            if let path = Self.resolveExecutablePath(names: names) {
                if (try? ProcessRunner.run(executable: path, arguments: args))?.succeeded == true {
                    return (true, path)
                }
            }
            // 3) 用户登录 shell 兜底：加载 ~/.zshrc / ~/.zprofile，能拾取所有用户自配 PATH
            for name in names {
                let cv = try? ProcessRunner.run(
                    executable: "/bin/zsh",
                    arguments: ["-ilc", "command -v \(name)"]
                )
                guard let r = cv, r.succeeded else { continue }
                let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, fm.isExecutableFile(atPath: path),
                   (try? ProcessRunner.run(executable: path, arguments: args))?.succeeded == true {
                    return (true, path)
                }
            }
            return (false, nil)
        }.value
    }

    /// 在常见绝对路径里搜索可执行文件（不实际运行）。命中即返回。
    /// nonisolated 让 Task.detached 里的后台线程也能调到。
    nonisolated private static func resolveExecutablePath(names: [String]) -> String? {
        let fm = FileManager.default
        let home = NSString("~").expandingTildeInPath
        var dirs: [String] = [
            // Homebrew
            "/opt/homebrew/bin",
            "/usr/local/bin",
            // MacPorts
            "/opt/local/bin",
            // python.org installer
            "/Library/Frameworks/Python.framework/Versions/3.13/bin",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin",
            // 用户级
            "\(home)/.local/bin",
            "\(home)/.pyenv/shims",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/miniconda3/bin",
            "\(home)/anaconda3/bin",
            "\(home)/mambaforge/bin",
            "\(home)/miniforge3/bin",
            // Apple system
            "/usr/bin",
            "/bin"
        ]
        // 也尝试 Homebrew Cellar 里的 keg-only 工具：/opt/homebrew/opt/<name>/bin
        for n in names {
            dirs.append("/opt/homebrew/opt/\(n)/bin")
            dirs.append("/usr/local/opt/\(n)/bin")
        }
        for dir in dirs {
            for name in names {
                let candidate = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// 用解析到的 python3（必要时）测试 import。
    private func pythonImport(_ module: String, python: String = "python3") async -> Bool {
        await Task.detached(priority: .utility) {
            (try? ProcessRunner.run(executable: python,
                                   arguments: ["-c", "import \(module)"]))?.succeeded == true
        }.value
    }
}

// MARK: - PermissionsView

struct PermissionsView: View {
    @Bindable var model: PermissionsModel
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            Text("权限检查")
                .font(.largeTitle.bold())
            Text("需要开启系统权限并确认开发工具就绪，才能完整使用 AIMA（会议助手）。")
                .foregroundStyle(.secondary)

            hardwareBanner

            // ── 系统权限 ──────────────────────────────────────
            Text("系统权限").font(.headline).foregroundStyle(.secondary)

            permRow(
                title: "麦克风",
                ok: model.micGranted,
                hint: "用于录制你自己的声音",
                action: { Task { await model.requestMic() } },
                actionLabel: "请求权限"
            )

            permRow(
                title: "屏幕录制（含系统音频）",
                ok: model.screenGranted,
                hint: "用于采集会议对端声音。首次会弹出系统授权窗口。",
                action: { Task { await model.probeScreen() } },
                actionLabel: model.checking ? "检查中…" : "检查/请求"
            )

            // ── 工具依赖 ──────────────────────────────────────
            HStack {
                Text("工具依赖").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if model.checkingDeps {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("重新检查") { Task { await model.checkDeps() } }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

            // 按顺序的"下一步"指引（有依赖关系：python3/ffmpeg → pip 包）
            if let step = nextInstallStep { installGuideCard(step) }

            VStack(spacing: 8) {
                ForEach(Array(installSteps.enumerated()), id: \.offset) { idx, step in
                    depRow(
                        index: idx + 1,
                        name: step.name,
                        result: step.result,
                        hint: step.hint,
                        fix: step.command,
                        optional: step.optional,
                        blocked: step.isBlocked
                    )
                }
            }

            // ── AI 模型缓存 ──────────────────────────────────
            Text("AI 模型").font(.headline).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                modelRow(
                    name: "Whisper",
                    currentID: model.currentWhisperID,
                    result: model.whisperModel,
                    recommended: model.recommendedWhisper,
                    installCmd: "huggingface-cli download \(model.currentWhisperID)"
                )
                modelRow(
                    name: "Gemma",
                    currentID: model.currentGemmaID,
                    result: model.gemmaModel,
                    recommended: model.recommendedGemma,
                    installCmd: "huggingface-cli download \(model.currentGemmaID)"
                )
                modelRow(
                    name: "pyannote",
                    currentID: model.currentPyannoteID,
                    result: model.pyannoteModel,
                    recommended: nil,
                    installCmd: "HF_TOKEN=$(cat ~/.hf_token) huggingface-cli download \(model.currentPyannoteID)",
                    optional: true
                )
            }

            // 扫描状态提示
            if model.checkingDeps {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在扫描工具依赖…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.python3.state == .pending {
                Text("点击「重新检查」以验证工具依赖。")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if model.requiredDepsOK {
                Label("所有必需工具已就绪。", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("部分必需工具缺失。请复制上方命令安装后点击「重新检查」。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if !model.checksDone {
                    ProgressView().controlSize(.small)
                    Text("等待检查完成…").font(.caption).foregroundStyle(.secondary)
                } else if !entryBlockers.isEmpty {
                    Label(entryBlockers.joined(separator: "、") + " 未就绪",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("进入", action: onContinue)
                    .disabled(!canEnter)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 520)
        .task {
            async let s: Void = model.probeScreen()
            async let d: Void = model.checkDeps()
            _ = await (s, d)
        }
        .onChange(of: canEnter) { _, ok in
            if ok { onContinue() }
        }
    }

    // 严格进入条件：系统权限 + 必需工具 + 必需模型缓存（pyannote/其模型为可选）
    private var canEnter: Bool {
        model.checksDone
            && model.allGranted
            && model.requiredDepsOK
            && model.whisperModel.state == .ok
            && model.gemmaModel.state == .ok
    }

    private var entryBlockers: [String] {
        var out: [String] = []
        if !model.micGranted        { out.append("麦克风") }
        if !model.screenGranted     { out.append("屏幕录制") }
        if model.brewEffectivelyRequired && model.brew.state != .ok { out.append("Homebrew") }
        if model.python3.state    != .ok { out.append("python3") }
        if model.ffmpeg.state     != .ok { out.append("ffmpeg") }
        if model.hfCliEffectivelyRequired && model.hfCli.state != .ok { out.append("huggingface-cli") }
        if model.mlxWhisper.state != .ok { out.append("mlx_whisper") }
        if model.mlxVlm.state     != .ok { out.append("mlx_vlm") }
        if model.whisperModel.state != .ok { out.append("Whisper 模型") }
        if model.gemmaModel.state   != .ok { out.append("Gemma 模型") }
        return out
    }

    // MARK: Hardware banner

    private var hardwareBanner: some View {
        let hw = model.hardware
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: hw.isAppleSilicon ? "cpu.fill" : "cpu")
                .foregroundStyle(.blue)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hw.chip).font(.callout.weight(.medium))
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(format: "%.0f GB 内存", hw.ramGB))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(hw.tierLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.blue.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.blue)
                }
                Text("推荐 Whisper：\(model.recommendedWhisper.id)  （\(model.recommendedWhisper.size)，\(model.recommendedWhisper.note)）")
                    .font(.caption).foregroundStyle(.secondary)
                Text("推荐 Gemma：\(model.recommendedGemma.id)  （\(model.recommendedGemma.size)，\(model.recommendedGemma.note)）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Row builders

    @ViewBuilder
    private func permRow(title: String, ok: Bool, hint: String,
                         action: @escaping () -> Void, actionLabel: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(hint).foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            if !ok {
                Button(actionLabel, action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func depIcon(result: PermissionsModel.DepResult, optional: Bool) -> some View {
        switch result.state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(optional ? .orange : .red)
        }
    }

    @ViewBuilder
    private func depRow(index: Int, name: String, result: PermissionsModel.DepResult,
                        hint: String, fix: String, optional: Bool = false,
                        blocked: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // 步骤编号圆圈
            Text("\(index)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(blocked ? Color.secondary : Color.white)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(stepBadgeColor(result: result, blocked: blocked))
                )

            depIcon(result: result, optional: optional)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(.callout, design: .monospaced))
                    if optional {
                        Text("可选").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                    if blocked {
                        Text("待前置步骤").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
                Text(hint).font(.caption).foregroundStyle(.secondary)
                if result.state == .ok, let p = result.resolvedPath {
                    Text(p)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if result.state != .ok {
                    HStack(spacing: 6) {
                        Text(fix)
                            .font(.caption.monospaced())
                            .foregroundStyle(blocked ? Color.secondary : Color.blue)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fix, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("复制命令")
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(blocked ? 0.07 : 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(blocked ? 0.55 : 1.0)
    }

    private func stepBadgeColor(result: PermissionsModel.DepResult, blocked: Bool) -> Color {
        if result.state == .ok { return .green }
        if blocked { return .secondary.opacity(0.5) }
        if result.state == .missing { return .orange }
        return .gray.opacity(0.6)
    }

    // MARK: - Install step sequencing

    struct InstallStep: Identifiable {
        let id: String
        let name: String
        let hint: String
        let command: String
        let optional: Bool
        let result: PermissionsModel.DepResult
        let isBlocked: Bool
    }

    private var installSteps: [InstallStep] {
        let brewOK = model.brew.state == .ok
        let pyOK   = model.python3.state == .ok
        let brewInstall = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        return [
            .init(id: "brew", name: "Homebrew",
                  hint: model.brewEffectivelyRequired
                        ? "macOS 包管理器（用于安装 python3/ffmpeg）"
                        : "已不再需要（python3 与 ffmpeg 均已就绪）",
                  command: brewInstall,
                  optional: !model.brewEffectivelyRequired,
                  result: model.brew, isBlocked: false),
            .init(id: "python3", name: "python3",
                  hint: "Python 运行时（后续 pip 依赖都需要，Homebrew 安装）",
                  command: "brew install python3",
                  optional: false, result: model.python3, isBlocked: !brewOK),
            .init(id: "ffmpeg", name: "ffmpeg",
                  hint: "音频处理工具（Homebrew 安装）",
                  command: "brew install ffmpeg",
                  optional: false, result: model.ffmpeg, isBlocked: !brewOK),
            .init(id: "huggingface-cli", name: "huggingface-cli",
                  hint: model.hfCliEffectivelyRequired
                        ? "下载 Whisper / Gemma / pyannote 模型（需先完成 python3）"
                        : "已不再需要（必需模型已下载完成）",
                  command: "pip3 install -U \"huggingface_hub[cli]\"",
                  optional: !model.hfCliEffectivelyRequired,
                  result: model.hfCli, isBlocked: !pyOK),
            .init(id: "mlx_whisper", name: "mlx_whisper",
                  hint: "语音转文字（必需，需先完成 python3）",
                  command: "pip3 install mlx-whisper",
                  optional: false, result: model.mlxWhisper, isBlocked: !pyOK),
            .init(id: "mlx_vlm", name: "mlx_vlm",
                  hint: "纪要生成（必需，需先完成 python3）",
                  command: "pip3 install mlx-vlm",
                  optional: false, result: model.mlxVlm, isBlocked: !pyOK),
            .init(id: "pyannote.audio", name: "pyannote.audio",
                  hint: "说话人识别（可选，需先完成 python3）",
                  command: "pip3 install pyannote.audio",
                  optional: true, result: model.pyannote, isBlocked: !pyOK)
        ]
    }

    /// 下一步应该安装的项：排除已 OK 和被前置阻塞的，必需项优先于可选。
    private var nextInstallStep: InstallStep? {
        let pending = installSteps.filter {
            $0.result.state == .missing && !$0.isBlocked
        }
        return pending.first(where: { !$0.optional }) ?? pending.first
    }

    @ViewBuilder
    private func installGuideCard(_ step: InstallStep) -> some View {
        let idx = (installSteps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1
        let total = installSteps.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.blue)
                Text("下一步 · 第 \(idx) / \(total) 步")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(step.optional ? "可选" : "必需")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(step.optional ? Color.gray.opacity(0.2) : Color.orange.opacity(0.2))
                    .clipShape(Capsule())
                    .foregroundStyle(step.optional ? Color.secondary : Color.orange)
            }
            Text("安装 \(step.name)：\(step.hint)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(step.command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(step.command, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("在终端执行完成后，点击上方「重新检查」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.blue.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.blue.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func modelRow(
        name: String,
        currentID: String,
        result: PermissionsModel.DepResult,
        recommended: PermissionsModel.ModelSpec?,
        installCmd: String,
        optional: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            depIcon(result: result, optional: optional)
                .font(.body)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(.medium))
                    if optional {
                        Text("可选").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                    if let rec = recommended, rec.id != currentID {
                        Text("推荐换用：\(rec.id.components(separatedBy: "/").last ?? rec.id)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(currentID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if result.state == .missing {
                    Text(installCmd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
