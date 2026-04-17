# 工程目录结构与核心数据模型

## 目标

本文档用于锁定第一阶段的工程目录结构和核心数据模型，避免实现过程中边写边改架构。

---

## 工程目录结构

当前仓库建议采用以下结构：

```text
meetingSummary/
├── docs/
│   ├── 01_environment_baseline.md
│   ├── 02_macos_native_mvp_plan.md
│   ├── 03_phase1_kickoff.md
│   └── 04_project_structure_and_data_model.md
├── macos-app/
│   ├── Package.swift
│   ├── Sources/
│   │   └── MeetingSummaryApp/
│   │       ├── App/
│   │       │   ├── MeetingSummaryApp.swift
│   │       │   └── AppViewModel.swift
│   │       ├── Models/
│   │       │   ├── PermissionModels.swift
│   │       │   ├── RecordingModels.swift
│   │       │   ├── ProcessingModels.swift
│   │       │   └── SessionModels.swift
│   │       ├── Features/
│   │       │   ├── Permissions/
│   │       │   │   └── PermissionsView.swift
│   │       │   ├── Recording/
│   │       │   │   └── RecordingView.swift
│   │       │   └── Results/
│   │       │       └── ResultsView.swift
│   │       ├── Shared/
│   │       │   ├── RootView.swift
│   │       │   └── StatusBadge.swift
│   │       └── Services/
│   │           └── Placeholder/
│   │               └── README.md
│   └── Resources/
└── Impromptu.m4a
```

---

## 目录说明

### `docs/`

- 保存产品方案、环境基线、任务拆解、工程设计文档。

### `macos-app/`

- 保存 macOS 原生应用工程。
- 第一阶段采用 Swift Package 方式搭骨架。
- 当前目标系统版本：`macOS 15+`
- 原因是当前机器只有 Command Line Tools，没有完整 Xcode，但 `swift build` 可用。

### `App/`

- 保存应用入口和全局状态容器。
- 所有页面共享的应用状态从这里流出。

### `Models/`

- 保存轻量且稳定的数据结构。
- 不把状态字段散落到 View 内部。

### `Features/`

- 每个页面或功能域一个目录。
- 第一阶段只保留：
  - `Permissions`
  - `Recording`
  - `Results`

### `Shared/`

- 跨页面共用视图。
- 包括根路由和通用状态展示组件。

### `Services/`

- 当前先放占位，后续逐步接入：
  - 权限服务
  - 录音服务
  - 处理编排服务
  - Whisper Runner
  - Gemma Runner

---

## 核心数据模型

第一阶段不追求“大而全”，只固化最必要的状态模型。

### 1. 权限模型

#### `PermissionKind`

表示权限类型：

- `microphone`
- `systemAudioCapture`

#### `PermissionStatus`

表示权限状态：

- `unknown`
- `granted`
- `denied`

#### `PermissionItem`

用于驱动权限页展示：

- `kind`
- `title`
- `description`
- `status`

---

### 2. 录音模型

#### `RecordingSource`

表示录音输入来源：

- `microphone`
- `systemAudio`

#### `RecordingState`

表示录音链路状态：

- `idle`
- `ready`
- `recording`
- `stopping`
- `failed`

#### `RecordingConfiguration`

表示录音时启用的输入源：

- `enabledSources`

第一阶段默认：

- 系统声音开启
- 麦克风开启

---

### 3. 处理状态模型

#### `ProcessingStage`

表示 AI 处理链路阶段：

- `idle`
- `savingAudio`
- `transcribing`
- `parsingTranscript`
- `summarizing`
- `completed`
- `failed`

#### `ProcessingStatus`

用于 UI 展示的处理状态对象：

- `stage`
- `message`
- `errorMessage`

---

### 4. Session 模型

#### `SessionArtifact`

表示一次会话中生成的文件：

- `audioFilePath`
- `transcriptJSONPath`
- `transcriptTextPath`
- `meetingMinutesPath`
- `logFilePath`

#### `SessionSummary`

表示一次处理结果在 UI 中的摘要：

- `id`
- `createdAt`
- `artifacts`
- `transcriptText`
- `meetingMinutesMarkdown`

---

### 5. 全局应用状态模型

#### `AppScreen`

表示当前页面：

- `permissions`
- `recording`
- `results`

#### `AppViewModel`

全局状态容器，第一阶段负责：

- 保存权限状态
- 保存录音状态
- 保存处理状态
- 保存当前结果
- 提供页面跳转依据

核心职责：

1. 不把业务状态散到多个 View 中
2. 所有页面都通过统一状态驱动
3. 为后续接真实权限、真实录音、真实处理流程预留稳定接口

---

## 页面状态流

第一阶段页面流转规则如下：

1. 默认先进入 `permissions`
2. 当全部权限满足时进入 `recording`
3. 当录音与处理完成后进入 `results`
4. 结果页允许返回 `recording`

对应关系：

```text
permissions -> recording -> results
```

失败规则：

- 权限失败留在权限页
- 录音失败留在录音页
- 处理失败留在录音页并展示错误

---

## 第一阶段实现策略

第一阶段的 UI 与状态模型先用“假流程”验证结构是否合理：

1. 权限页先支持模拟授权通过
2. 录音页先支持开始/停止假录音
3. 停止后模拟生成 transcript 和纪要
4. 结果页验证展示结构

这样可以先把产品骨架搭稳，再替换成真实服务。

---

## 结论

当前工程结构与核心数据模型以本文档为准。  
后续实现如需改动，应优先修改本文档，再改代码。
