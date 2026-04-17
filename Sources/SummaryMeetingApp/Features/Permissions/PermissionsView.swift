import SwiftUI
import AVFoundation

@MainActor
@Observable
final class PermissionsModel {
    var micGranted: Bool = MicRecorder.isAuthorized
    var screenGranted: Bool = false
    var checking: Bool = false

    func requestMic() async {
        micGranted = await MicRecorder.requestPermission()
    }

    func probeScreen() async {
        checking = true
        defer { checking = false }
        screenGranted = await SystemAudioRecorder.requestPermissionPrompt()
    }

    var allGranted: Bool { micGranted && screenGranted }
}

struct PermissionsView: View {
    @Bindable var model: PermissionsModel
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("权限检查")
                .font(.largeTitle.bold())
            Text("需要开启两项权限才能录制完整的会议音频。")
                .foregroundStyle(.secondary)

            row(
                title: "麦克风",
                ok: model.micGranted,
                hint: "用于录制你自己的声音",
                action: { Task { await model.requestMic() } },
                actionLabel: "请求权限"
            )

            row(
                title: "屏幕录制（含系统音频）",
                ok: model.screenGranted,
                hint: "用于采集会议对端声音。首次会弹出系统授权窗口。",
                action: { Task { await model.probeScreen() } },
                actionLabel: model.checking ? "检查中…" : "检查/请求"
            )

            Spacer()

            HStack {
                Spacer()
                Button("进入", action: onContinue)
                    .disabled(!model.micGranted)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 380)
        .task {
            await model.probeScreen()
        }
        .onChange(of: model.allGranted) { _, granted in
            if granted { onContinue() }
        }
    }

    @ViewBuilder
    private func row(title: String, ok: Bool, hint: String, action: @escaping () -> Void, actionLabel: String) -> some View {
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
}
