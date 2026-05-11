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
    /// Picker 授权成功但尚未固定到 TCC 持久列表时显示"点 + 固定"提示
    var showPersistentPermHint: Bool = false

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

        enum Tier: String { case ultraLow, low, mid, high }
        var tier: Tier {
            if ramGB >= 32 { return .high }
            if ramGB >= 16 { return .mid }
            if ramGB >= 12 { return .low }
            return .ultraLow
        }
        var tierLabel: String {
            switch tier {
            case .ultraLow: return "极低配（<12GB，OOM 风险高）"
            case .low:      return "入门（12-16GB）"
            case .mid:      return "标准（16-32GB）"
            case .high:     return "高配（≥32GB）"
            }
        }
    }

    let hardware: Hardware = PermissionsModel.detectHardware()

    // MARK: HF 镜像探测
    /// huggingface.co 是否可直连。nil = 未探测；true = 直连；false = 推荐镜像。
    /// 在 checkDeps 末尾自动探测；UI 据此切换 `hf download` 命令是否带 `HF_ENDPOINT` 前缀。
    var hfReachable: Bool? = nil

    /// 5 秒短超时探测 hf.co；只看 TCP/TLS 是否通和返回非网络错误，不关心 HTTP code。
    func probeHFReachable() async {
        let url = URL(string: "https://huggingface.co/api/whoami")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.httpMethod = "HEAD"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        let session = URLSession(configuration: cfg)
        do {
            _ = try await session.data(for: req)
            self.hfReachable = true
        } catch {
            // 连不通（DNS、超时、TLS、443 被墙）→ 切镜像
            self.hfReachable = false
        }
    }

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
    /// Whisper 1.5 GB 占用极小，所有 Apple Silicon 档位统一推荐 turbo（速度优化版的 large-v3），
    /// RAM 不参与 Whisper 选型。
    var recommendedWhisper: ModelSpec {
        .init(id: "mlx-community/whisper-large-v3-turbo",
              size: "~1.5GB",
              note: "Apple Silicon 全档位推荐：基于 large-v3 的速度优化版，质量接近 large-v3")
    }
    var recommendedGemma: ModelSpec {
        switch hardware.tier {
        case .ultraLow: return .init(id: "mlx-community/gemma-4-e2b-it-4bit",     size: "~1.5-2GB", note: "Gemma 4 e2b（最小档），8GB 内存勉强可跑；纪要质量明显弱于 e4b/26b")
        case .low:      return .init(id: "mlx-community/gemma-4-e4b-it-4bit",     size: "~3GB",     note: "Gemma 4 Any-to-Any 轻量版（~8B 总），小内存可用")
        case .mid:      return .init(id: "mlx-community/gemma-4-26b-a4b-it-4bit", size: "~15-18GB", note: "当前默认；MoE 架构，26B 总 / 4B 激活，速度接近 4B、质量接近稠密 26B")
        case .high:     return .init(id: "mlx-community/gemma-4-31b-it-4bit",     size: "~18-22GB", note: "Gemma 4 稠密 31B，质量最佳（需 ≥32GB 统一内存）")
        }
    }
    /// 当前运行时使用的模型 id（和 Runner 中的常量对应）
    /// 检测/安装命令引用的"当前模型 ID"——直接由推荐档位驱动，
    /// 保证 推荐显示 / 安装命令 / 检测 / GemmaRunner 运行时四处共用同一个 ID。
    /// （Whisper 全档位统一为 large-v3-turbo；pyannote 仅一个 community-1。）
    var currentWhisperID: String { recommendedWhisper.id }
    var currentGemmaID: String   { recommendedGemma.id }
    let currentPyannoteID = "pyannote/speaker-diarization-community-1"

    // MARK: Actions

    func requestMic() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            micGranted = true
        case .notDetermined:
            micGranted = await MicRecorder.requestPermission()
        case .denied, .restricted:
            // 已拒绝：requestAccess 不会弹框，必须跳转系统设置
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        @unknown default:
            micGranted = await MicRecorder.requestPermission()
        }
    }

    /// 按钮标签：denied 时改为"去系统设置"
    var micActionLabel: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return "去系统设置"
        default: return "请求权限"
        }
    }

    /// silent=true：仅检查当前状态，不触发系统弹窗（用于 View 出现时的静默探测）。
    /// silent=false：通过 SCContentSharingPicker 请求本次会话权限，
    ///              完成后自动打开系统设置，引导用户固定授权（一次性操作，之后永久生效）。
    func probeScreen(silent: Bool = false) async {
        checking = true
        defer { checking = false }
        if silent {
            screenGranted = SystemAudioRecorder.hasPermission()
        } else {
            let granted = await SystemAudioRecorder.presentPickerForPermission()
            screenGranted = granted
            // Picker 授权是会话级的；若尚未进入 TCC 持久列表，
            // 自动打开系统设置，引导用户点 + 固定授权（只需做一次）。
            if granted && !SystemAudioRecorder.hasPersistentPermission() {
                showPersistentPermHint = true
                SystemAudioRecorder.openScreenCaptureSettings()
            }
        }
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

        // hf.co 直连可达性探测（5s 超时；不可达 → 推荐镜像）
        async let hfPing: Void = probeHFReachable()

        let (v2, v3, v4) = await (r2, r3, r4)
        let (w, g, p) = await (m0, m1, m2)
        await hfPing
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
    /// HF 缓存用符号链接：snapshots/<sha>/* → ../../blobs/<sha256>。
    /// 用户清理 blobs/ 后符号链接断掉但仍存在；只判断"有没有文件"会误报为已下载。
    /// 这里递归遍历整个 snapshot 树（pyannote 等 pipeline 模型在子目录里放权重），
    /// realpath 解析符号链接，累加目标文件实际大小，必须超过最低阈值才认为完整。
    private static func modelCached(_ hfId: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let folder = "models--" + hfId.replacingOccurrences(of: "/", with: "--")
            let snapshots = home.appendingPathComponent(".cache/huggingface/hub/\(folder)/snapshots")
            guard let snaps = try? fm.contentsOfDirectory(atPath: snapshots.path),
                  !snaps.isEmpty else { return false }
            // 阈值 10 MB：覆盖 pyannote community-1（~30-50MB），同时拒绝只剩 config/tokenizer 等空壳。
            let minBytes: Int64 = 10_000_000
            for snap in snaps {
                let snapDir = snapshots.appendingPathComponent(snap)
                // 递归枚举所有子文件（pyannote 模型在子目录里有 .bin/.ckpt 权重）
                guard let enumerator = fm.enumerator(at: snapDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: []) else { continue }
                var totalBytes: Int64 = 0
                for case let url as URL in enumerator {
                    // realpath 解析所有层符号链接；目标不存在（断链）返回 nil → 跳过
                    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
                    guard realpath(url.path, &buf) != nil else { continue }
                    let resolved = String(cString: buf)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: resolved, isDirectory: &isDir),
                          !isDir.boolValue,
                          let attrs = try? fm.attributesOfItem(atPath: resolved),
                          let size = (attrs[.size] as? NSNumber)?.int64Value
                    else { continue }
                    totalBytes += size
                    if totalBytes >= minBytes { return true }
                }
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
            // 1) 优先走用户登录 shell 的 PATH——最贴近他们 Terminal 实际能跑的二进制位置；
            //    GUI 启动的 .app 自身环境变量被压缩了，这层最准。
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
            // 2) 裸名走 ProcessRunner.augmentedPath（Python framework + Homebrew）
            for name in names {
                if (try? ProcessRunner.run(executable: name, arguments: args))?.succeeded == true {
                    if let resolved = Self.resolveExecutablePath(names: [name]) {
                        return (true, resolved)
                    }
                    return (true, nil)
                }
            }
            // 3) 兜底扩展绝对路径列表
            if let path = Self.resolveExecutablePath(names: names) {
                if (try? ProcessRunner.run(executable: path, arguments: args))?.succeeded == true {
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
        // pip3 install --user 装的 CLI 会落到 ~/Library/Python/<version>/bin。
        // 用 glob 扫描该目录下所有 Python 版本，避免硬编码 3.11/3.12/3.13。
        let userPyRoot = "\(home)/Library/Python"
        if let entries = try? fm.contentsOfDirectory(atPath: userPyRoot) {
            for entry in entries {
                dirs.append("\(userPyRoot)/\(entry)/bin")
            }
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

/// 可折叠分区：标题 + 右侧扩展操作（如"重新检查"）+ 折叠箭头。
/// allOK 翻转时会自动调整展开状态：全 OK → 收起；出现问题 → 自动展开。
/// 用户手动点击则覆盖至下一次 allOK 翻转。
private struct CollapsibleSection<Trailing: View, Content: View>: View {
    let title: String
    let allOK: Bool
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    @State private var expanded: Bool

    init(title: String,
         allOK: Bool,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.allOK = allOK
        self.trailing = trailing
        self.content = content
        self._expanded = State(initialValue: !allOK)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .animation(.easeInOut(duration: 0.15), value: expanded)
                Text(title).font(.headline).foregroundStyle(.secondary)
                if allOK {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
                trailing()
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: allOK) { _, ok in
            // 状态翻转：全 OK → 自动收起；出现问题 → 自动展开。
            withAnimation(.easeInOut(duration: 0.2)) { expanded = !ok }
        }
    }
}

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
            CollapsibleSection(title: "系统权限", allOK: model.allGranted) {
                VStack(spacing: 8) {
                    permRow(
                        title: "麦克风",
                        ok: model.micGranted,
                        hint: "用于录制你自己的声音",
                        action: { Task { await model.requestMic() } },
                        actionLabel: model.micActionLabel
                    )
                    if model.screenGranted {
                        permRow(
                            title: "屏幕录制（含系统音频）",
                            ok: true,
                            hint: "用于采集会议对端声音",
                            action: {},
                            actionLabel: ""
                        )
                    } else {
                        screenPermCard
                    }
                }
            }

            // ── 工具依赖 ──────────────────────────────────────
            // "重新检查"按钮：默认放工具依赖；工具依赖全 OK 后挪到 AI 模型那行。
            CollapsibleSection(title: "工具依赖", allOK: model.requiredDepsOK) {
                if !model.requiredDepsOK { recheckButton }
            } content: {
                VStack(spacing: 8) {
                    // 按顺序的"下一步"指引（有依赖关系：python3/ffmpeg → pip 包）
                    if let step = nextInstallStep { installGuideCard(step) }

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
            }

            // ── AI 模型缓存 ──────────────────────────────────
            CollapsibleSection(title: "AI 模型", allOK: requiredModelsOK) {
                if model.requiredDepsOK { recheckButton }
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    if model.hfReachable == false {
                        Label("检测到 huggingface.co 直连不可达，已自动切换到 hf-mirror.com 镜像。",
                              systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if model.hfReachable == nil {
                        Label("正在检测 huggingface.co 可达性…未完成前命令暂用镜像版本。",
                              systemImage: "ellipsis.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let step = nextModelStep {
                        let idx = (modelSteps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1
                        installGuideCard(step, index: idx, total: modelSteps.count)
                    }
                    ForEach(Array(modelSteps.enumerated()), id: \.offset) { idx, step in
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
            async let s: Void = model.probeScreen(silent: true)
            async let d: Void = model.checkDeps()
            _ = await (s, d)
        }
        // 仅当 全部必备 + 全部选备（含 pyannote）均通过 时自动进入，且只触发一次。
        .onChange(of: allFullyOK) { _, ok in
            if ok { onContinue() }
        }
    }

    // 严格进入条件：Apple Silicon + 系统权限 + 必需工具 + 必需模型缓存（pyannote/其模型为可选）
    private var canEnter: Bool {
        model.hardware.isAppleSilicon
            && model.checksDone
            && model.allGranted
            && model.requiredDepsOK
            && model.whisperModel.state == .ok
            && model.gemmaModel.state == .ok
    }

    /// 所有必备 + 所有选备（pyannote 包 + 模型）全部通过 → 自动进入
    private var allFullyOK: Bool {
        canEnter
            && model.pyannote.state    == .ok
            && model.pyannoteModel.state == .ok
    }

    private var entryBlockers: [String] {
        var out: [String] = []
        if !model.hardware.isAppleSilicon { out.append("Apple Silicon") }
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

    /// 通用"重新检查"按钮：根据当前 checkingDeps 状态自动显示 spinner / 按钮。
    /// 一次跑屏幕权限 + 工具/模型/hf 网络可达性。
    @ViewBuilder
    private var recheckButton: some View {
        if model.checkingDeps {
            ProgressView().controlSize(.mini)
        } else {
            Button {
                Task {
                    async let s: Void = model.probeScreen()
                    async let d: Void = model.checkDeps()
                    _ = await (s, d)
                }
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private var hardwareBanner: some View {
        let hw = model.hardware
        let unsupported = !hw.isAppleSilicon
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: unsupported ? "exclamationmark.triangle.fill" : "cpu.fill")
                .foregroundStyle(unsupported ? .red : .blue)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hw.chip).font(.callout.weight(.medium))
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(format: "%.0f GB 内存", hw.ramGB))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(unsupported ? "不支持" : hw.tierLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background((unsupported ? Color.red : Color.blue).opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(unsupported ? Color.red : Color.blue)
                }
                if unsupported {
                    Text("AIMA 仅支持 Apple Silicon（M1/M2/M3/M4 系列）。Intel Mac 无 MLX 后端，无法本地运行 Whisper/Gemma。")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("推荐 Whisper：\(model.recommendedWhisper.id)  （\(model.recommendedWhisper.size)，\(model.recommendedWhisper.note)）")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("推荐 Gemma：\(model.recommendedGemma.id)  （\(model.recommendedGemma.size)，\(model.recommendedGemma.note)）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background((unsupported ? Color.red : Color.blue).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Screen permission card

    /// 屏幕录制权限卡片。
    /// 未授权：显示 Picker 按钮 + 引导说明。
    /// Picker 已授权但未固定（会话级）：显示"点 + 固定授权"提示。
    @ViewBuilder
    private var screenPermCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("屏幕录制（含系统音频）")
                        .font(.headline)
                    Text("用于采集会议对端声音")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.probeScreen() }
                } label: {
                    Label(model.checking ? "请求中…" : "授权录制", systemImage: "record.circle")
                }
                .disabled(model.checking)
            }

            Divider()

            if model.showPersistentPermHint {
                // Picker 授权成功，但是会话级的——引导用户一次性固定
                VStack(alignment: .leading, spacing: 6) {
                    Label("本次已授权，但每次启动仍需重复操作。", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Text("在刚刚弹出的系统设置里：点击「录屏与系统录音」或「仅系统录音」下方的 **+** 号，选择 AIMA.app 添加——只需做一次，之后永久生效。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("再次打开系统设置") {
                        SystemAudioRecorder.openScreenCaptureSettings()
                    }
                    .font(.callout)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("点击「授权录制」，在弹出的窗口中选择任意屏幕，即可完成本次授权。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.2))
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
            // Homebrew Python 自 PEP 668 起对 system pip 装包加锁；统一用 --break-system-packages --user
            // 装到用户级 site-packages（~/Library/Python/3.x/lib/python/site-packages 与 .../bin），
            // 既不污染系统也不需要 venv，python3 import 默认能找到。
            // 用 `python3 -m pip` 而非 `pip3`，确保 pip 与 .app 调用的 python3 同一个解释器，
            // 避免 pip3 装到 A、app 用 B 的 user-site 而 import 失败。
            // hf-cli 推荐 pipx 装：每个 CLI 隔离 venv + 自动符号链到 ~/.local/bin/，
            // Python 升级也不会失效；远比 pip --user --break-system-packages 干净。
            .init(id: "huggingface-cli", name: "huggingface-cli",
                  hint: model.hfCliEffectivelyRequired
                        ? "下载 Whisper / Gemma / pyannote 模型（用 pipx 隔离安装，需先完成 brew + python3）"
                        : "已不再需要（必需模型已下载完成）",
                  command: "brew install pipx && pipx ensurepath && pipx install \"huggingface_hub[cli]\"",
                  optional: !model.hfCliEffectivelyRequired,
                  result: model.hfCli, isBlocked: !pyOK),
            .init(id: "mlx_whisper", name: "mlx_whisper",
                  hint: "语音转文字（必需，需先完成 python3）",
                  command: "python3 -m pip install --break-system-packages --user mlx-whisper",
                  optional: false, result: model.mlxWhisper, isBlocked: !pyOK),
            .init(id: "mlx_vlm", name: "mlx_vlm",
                  hint: "纪要生成（必需，需先完成 python3）",
                  command: "python3 -m pip install --break-system-packages --user mlx-vlm",
                  optional: false, result: model.mlxVlm, isBlocked: !pyOK),
            .init(id: "pyannote.audio", name: "pyannote.audio",
                  hint: "说话人识别（可选，需先完成 python3）",
                  command: "python3 -m pip install --break-system-packages --user pyannote.audio",
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

    /// 模型下载步骤（适配硬件档位）。前置阻塞条件：hf-cli 必需且未就绪。
    /// 命令前缀按 hf.co 直连可达性自动切换：
    ///   - 直连可达 (`model.hfReachable == true`) → 直接 `hf download X`
    ///   - 不可达 (`false`)，或探测尚未完成（`nil`，保守策略）→ `HF_ENDPOINT=https://hf-mirror.com hf download X`
    /// 关键：不要加 `--local-dir`——必须把模型下到默认 HF 缓存（~/.cache/huggingface/hub/...），
    /// 否则我们的 modelCached() 扫描查不到，UI 会一直显示"未下载"。
    private var modelSteps: [InstallStep] {
        let hfBlocked = model.hfCliEffectivelyRequired && model.hfCli.state != .ok
        let whisperID = model.recommendedWhisper.id
        let gemmaID = model.recommendedGemma.id
        let pyID = model.currentPyannoteID
        // 探测未完成时也用镜像（保守，避免给国内用户错误的不可用命令）
        let useMirror = (model.hfReachable != true)
        let prefix = useMirror ? "HF_ENDPOINT=https://hf-mirror.com " : ""
        return [
            .init(id: "model.whisper", name: "Whisper 模型",
                  hint: "\(whisperID)（\(model.recommendedWhisper.size)，\(model.recommendedWhisper.note)）",
                  command: "\(prefix)hf download \(whisperID)",
                  optional: false, result: model.whisperModel, isBlocked: hfBlocked),
            .init(id: "model.gemma", name: "Gemma 模型",
                  hint: "\(gemmaID)（\(model.recommendedGemma.size)，\(model.recommendedGemma.note)）",
                  command: "\(prefix)hf download \(gemmaID)",
                  optional: false, result: model.gemmaModel, isBlocked: hfBlocked),
            // pyannote/speaker-diarization-community-1 是 gated 模型，需要先登录 HF token：
            // 1) huggingface.co/settings/tokens 生成 read 权限的 token
            // 2) 在模型页 huggingface.co/pyannote/speaker-diarization-community-1 接受协议
            // 3) `hf auth login` 把 token 存到 ~/.cache/huggingface/token，之后 hf download 自动带 token。
            // hf auth login 也会访问 hf.co（验证 token），所以同样要带镜像前缀。
            .init(id: "model.pyannote", name: "pyannote 模型",
                  hint: "\(pyID)（说话人分离，可选；门控模型，首次需 hf auth login）",
                  command: "\(prefix)hf auth login && \(prefix)hf download \(pyID)",
                  optional: true, result: model.pyannoteModel, isBlocked: hfBlocked)
        ]
    }

    /// 必需模型是否全部就绪（pyannote 可选，不计入）
    private var requiredModelsOK: Bool {
        model.whisperModel.state == .ok && model.gemmaModel.state == .ok
    }

    private var nextModelStep: InstallStep? {
        let pending = modelSteps.filter {
            $0.result.state == .missing && !$0.isBlocked
        }
        return pending.first(where: { !$0.optional }) ?? pending.first
    }

    /// 通用引导卡：调用方按所属步骤列表给出 index/total。
    @ViewBuilder
    private func installGuideCard(_ step: InstallStep, index: Int? = nil, total: Int? = nil) -> some View {
        let idx = index ?? ((installSteps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1)
        let total = total ?? installSteps.count
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

}
