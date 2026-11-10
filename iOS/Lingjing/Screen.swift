import SwiftUI
import ReplayKit
import AVKit
import CoreImage

let sharedGroup = "group.com.liu.lingjing.translate"
// ReplayKit includes the system PiP in the captured picture on this device.
// AVKit exposes no PiP window coordinates, so a green frame in our video is
// located in captured frames and excluded from OCR and the next PiP frame.
private let broadcastStoppedNotification = "com.liu.lingjing.broadcastStopped"

/// Timing log shown in Xcode's console (filter "[QY]"). No screen text is logged.
func qyLog(_ message: String) {
    #if DEBUG
    let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    print("[QY] \(stamp) \(message)")
    #endif
}

enum TranslationScope: String, CaseIterable, Identifiable {
    case nearby = "画中画附近"
    case fullScreen = "整个屏幕"
    case fixed = "固定区域"
    var id: String { rawValue }
    var description: String {
        switch self {
        case .nearby: "识别右上角小窗周围的内容；小窗移动后需切换范围。"
        case .fullScreen: "识别屏幕上所有可见文字。"
        case .fixed: "只识别你在当前画面上框选的区域。"
        }
    }
    func contains(_ point: CGPoint, fixedRegion: CGRect) -> Bool {
        switch self {
        case .fullScreen: true
        case .fixed: fixedRegion.contains(point)
        case .nearby: CGRect(x: 0.25, y: 0.0, width: 0.75, height: 0.82).contains(point)
        }
    }
    func viewport(fixedRegion: CGRect) -> CGRect {
        switch self {
        case .fullScreen: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .fixed: fixedRegion
        case .nearby: CGRect(x: 0.25, y: 0, width: 0.75, height: 0.82)
        }
    }
}

enum ScreenDisplayMode: String, CaseIterable, Identifiable {
    case inPlace = "贴回原位"
    case subtitles = "屏幕字幕"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .inPlace: "在画中画的原文字位置显示译文。"
        case .subtitles: "只显示大字译文，底色和字色参考原文字区域。"
        }
    }
}

/// The system broadcast picker; `onTap` reports that the system 屏幕共享
/// sheet is being opened so the page can show 「等待系统确认」.
struct BroadcastPicker: UIViewRepresentable {
    var onTap: (() -> Void)? = nil
    func makeUIView(context: Context) -> FullWidthBroadcastPicker {
        let view = FullWidthBroadcastPicker(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        view.fillsBounds = false
        view.preferredExtension = "com.liu.lingjing.translate.broadcast"
        view.showsMicrophoneButton = false
        view.onTap = onTap
        return view
    }
    func updateUIView(_ view: FullWidthBroadcastPicker, context: Context) { view.onTap = onTap }
}

// Keep the system picker itself as the touch target; its default internal
// button can otherwise occupy only a small area of a wide SwiftUI control.
final class FullWidthBroadcastPicker: RPSystemBroadcastPickerView {
    var fillsBounds = true
    var onTap: (() -> Void)?
    private weak var hookedButton: UIButton?
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let button = HiddenBroadcastPicker.firstButton(in: self) else { return }
        if fillsBounds { button.frame = bounds }
        if hookedButton !== button {
            button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            hookedButton = button
        }
    }
    @objc private func tapped() { onTap?() }
}

/// An almost invisible system picker. Bumping `trigger` opens the system
/// 屏幕共享 sheet from our own button (after the short guide sheet).
struct HiddenBroadcastPicker: UIViewRepresentable {
    var trigger: Int
    final class Coordinator { var last = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        view.preferredExtension = "com.liu.lingjing.translate.broadcast"
        view.showsMicrophoneButton = false
        view.alpha = 0.011
        view.accessibilityElementsHidden = true
        context.coordinator.last = trigger
        return view
    }
    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {
        guard trigger != context.coordinator.last else { return }
        context.coordinator.last = trigger
        DispatchQueue.main.async {
            view.layoutIfNeeded()
            Self.firstButton(in: view)?.sendActions(for: .touchUpInside)
        }
    }
    static func firstButton(in view: UIView) -> UIButton? {
        for sub in view.subviews {
            if let button = sub as? UIButton { return button }
            if let button = firstButton(in: sub) { return button }
        }
        return nil
    }
}

struct VoiceBroadcastStartPicker: UIViewRepresentable {
    var onTap: () -> Void
    func makeUIView(context: Context) -> FullWidthBroadcastPicker {
        let view = FullWidthBroadcastPicker()
        view.preferredExtension = "com.liu.lingjing.translate.broadcast"
        view.showsMicrophoneButton = false
        view.alpha = 0.02
        view.accessibilityLabel = "开启字幕，打开系统广播面板"
        view.onTap = onTap
        return view
    }
    func updateUIView(_ view: FullWidthBroadcastPicker, context: Context) { view.onTap = onTap }
}

/// Short checklist shown before the system 屏幕共享 panel: three numbered
/// steps in the app's own card style, then the system panel opens.
struct BroadcastGuideSheet: View {
    let title: String
    let subtitle: String
    let steps: [(icon: String, text: String)]
    let note: String
    var onContinue: () -> Void
    var onNeverShow: () -> Void
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4

    var body: some View {
        if visualTheme == 5 { mistBody } else { standardBody }
    }

    private var mistBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            MistSheetHeader(title: title, subtitle: subtitle) { onContinueCancelled() }
            MistStepsCard(steps: steps.map { (title: "", detail: $0.text) })
            Label(note, systemImage: "lock.shield").font(Mist.light(13)).foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            MistPrimaryButton(title: "继续", systemImage: "arrow.right", action: onContinue)
            Button("以后不再显示", action: onNeverShow)
                .font(Mist.light(14)).foregroundStyle(.white).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 8)
        .background(MistBackground())
        .environment(\.colorScheme, .light)
        .presentationDetents([.height(540), .large])
        .presentationBackground { MistBackground() }
        .presentationCornerRadius(38)
    }

    @Environment(\.dismiss) private var dismissSheet
    private func onContinueCancelled() { dismissSheet() }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 0) {
                            Text("\(index + 1)").font(.footnote.weight(.bold))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .frame(width: 26, height: 26)
                                .background(Color.primary, in: Circle())
                            if index < steps.count - 1 {
                                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 2).frame(maxHeight: .infinity)
                            }
                        }
                        HStack(alignment: .top, spacing: 10) {
                            Text(step.text).font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: step.icon).font(.system(size: 17)).foregroundStyle(.secondary)
                        }
                        .padding(.top, 3).padding(.bottom, index < steps.count - 1 ? 18 : 0)
                    }
                }
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            Label(note, systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: onContinue) {
                Text("继续").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(.black, in: Capsule())
            }.buttonStyle(.plain)
            Button("以后不再显示", action: onNeverShow)
                .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 8)
        .background(Color(uiColor: .systemGroupedBackground))
        .presentationDetents([.height(500), .large])
        .presentationDragIndicator(.visible)
    }
}

/// Where screen translation is in its start flow; shared by every theme.
enum ScreenPhase: Equatable {
    case idle, waiting, starting, running, pipClosed

    @MainActor static func of(_ model: ScreenModel, _ pip: SubtitlePiP) -> ScreenPhase {
        if model.active && pip.isActuallyActive { return .running }
        if model.active && (pip.state.contains("关闭") || pip.state.contains("失败")) { return .pipClosed }
        if model.pipPrestarted || model.active { return .starting }
        if model.awaitingSystem { return .waiting }
        return .idle
    }

    var title: String {
        switch self {
        case .idle: "准备就绪"
        case .waiting: "等待系统确认"
        case .starting: "正在开启画中画"
        case .running: "翻译中"
        case .pipClosed: "画中画已关闭"
        }
    }
    var detail: String {
        switch self {
        case .idle: "点「开启翻译」，在系统面板里点「开始直播」，画中画会自动弹出。"
        case .waiting: "请在系统弹出的「屏幕共享」面板里点「开始直播」。"
        case .starting: "请留在本页，小窗弹出后再切到要看的 App。"
        case .running: "切到其他 App，把小窗放到要读的内容旁边，译文会实时显示。"
        case .pipClosed: "屏幕共享还在进行，点下方按钮重新打开小窗。"
        }
    }
    /// Position on the 雾面 arc (four stops).
    var progress: Double {
        switch self {
        case .idle: 0.125
        case .waiting: 0.375
        case .starting, .pipClosed: 0.625
        case .running: 0.875
        }
    }
}

/// Prominent status at the top of 屏幕翻译 (replaces the small hint text):
/// 准备就绪 → 等待系统确认 → 正在开启画中画 → 翻译中, each with what to do next.
struct ScreenStatusHero: View {
    @ObservedObject var model: ScreenModel
    @ObservedObject var pip: SubtitlePiP
    var onStart: () -> Void
    var onStop: () -> Void

    private var phase: ScreenPhase { ScreenPhase.of(model, pip) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 10, height: 10)
                    .shadow(color: dotColor.opacity(0.6), radius: 5)
                Text(title).font(.system(size: 28, weight: .bold))
                    .contentTransition(.opacity)
                if phase == .starting || phase == .waiting { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch phase {
            case .idle:
                primary("开启翻译", systemImage: "play.fill", color: .primary, action: onStart)
            case .waiting:
                primary("重新打开系统面板", systemImage: "record.circle", color: .primary, action: onStart)
                secondary("取消") { model.cancelAwaitingSystem() }
            case .starting, .running:
                primary("停止翻译", systemImage: "stop.fill", color: .primary, filled: false, action: onStop)
            case .pipClosed:
                primary("重新开启画中画", systemImage: "pip.enter", color: .primary) { pip.start() }
                secondary("停止翻译", action: onStop)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: title)
    }

    private var title: String { phase.title }
    private var detail: String { phase.detail }
    private var dotColor: Color {
        switch phase {
        case .idle: .gray
        case .waiting, .starting, .pipClosed: .orange
        case .running: .green
        }
    }
    private func primary(_ text: String, systemImage: String, color: Color, filled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: systemImage).font(.headline)
                .foregroundStyle(filled ? Color.white : color)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(filled ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)),
                            in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
    private func secondary(_ text: String, action: @escaping () -> Void) -> some View {
        Button(text, action: action).font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
    }
}

@MainActor final class ScreenModel: ObservableObject {
    @Published var active = false
    @Published var status = "准备就绪"
    @Published var source: AppLanguage = .auto
    @Published var target: AppLanguage = .simplifiedChinese
    @Published private(set) var scope: TranslationScope = .fullScreen
    @Published private(set) var displayMode: ScreenDisplayMode = .inPlace
    @Published private(set) var fixedRegion = CGRect(x: 0.1, y: 0.55, width: 0.8, height: 0.28)
    // The PiP layer updates independently; publishing every preview frame forces
    // SwiftUI to re-layout the entire home screen while the app is in the background.
    var latest: UIImage?
    @Published var translated = ""
    @Published var original = ""
    @Published var blocks: [TextBlock] = []
    private var lastFrameModified: Date = .distantPast
    private var lastOCRFrameModified: Date = .distantPast
    private var lastResultModified: Date = .distantPast
    private var generation = 0
    private var resultSignature = ""
    private var processingOCR = false
    private var translationTask: Task<Void, Never>?
    private var translationRenderTask: Task<Void, Never>?
    private var translationSequence = 0
    private var pendingPageTexts: Set<String>?
    private var pendingPageSeenAt = Date.distantPast
    private var knownTranslations: [String: String] = [:]
    private var failedTranslationKey = ""
    private var failedTranslationAt = Date.distantPast
    private var translationStage = "未开始"
    private var translationStarted = Date.distantPast
    private var lastOCRDurationMs = 0
    private var firstTranslationMs: Int?
    private var waitingAfterStall = false
    private let translator = LocalTranslator()
    private var lastDebugTrace = Date.distantPast
    private var loadingPreview = false
    private var lastPiPFound = Date.distantPast
    private var pipMismatchSince: Date?
    private var lastFramePresentMs = 0
    private var lastRenderMs = 0
    // Privacy-safe timing counters (no screen content). Shown in the Debug trace.
    private var lastOCRSignature: [UInt8] = []
    private var lastOCRRanAt = Date.distantPast
    private var forceOCR = true
    private var lastOCRSeenModified = Date.distantPast
    private var ocrFramesSeen = 0
    private var ocrFramesDroppedBusy = 0
    private var ocrFramesSkippedStatic = 0
    private var ocrFramesProcessed = 0
    private var lastOCRFrameAgeMs = 0
    private var currentOCRFrameTime = Date.distantPast
    private var firstTranslationFromFrameMs: Int?
    private var lastTranslationTotalMs = 0
    private var translationBatches = 0
    private var ocrReferenceProfile: [UInt8] = []
    /// PiP start was begun for a fresh broadcast (stale states excluded).
    @Published private(set) var pipPrestarted = false
    /// The system 屏幕共享 sheet was opened and we wait for the user to start.
    @Published private(set) var awaitingSystem = false
    private var awaitingSince = Date.distantPast
    /// The broadcast extension reports "running".
    @Published private(set) var broadcastRunning = false

    func beginAwaitingSystem() {
        guard !broadcastRunning else { return }
        awaitingSystem = true
        awaitingSince = Date()
        status = "等待系统确认"
        qyLog("system broadcast sheet opened")
        prewarmPipeline()
    }

    func cancelAwaitingSystem() {
        awaitingSystem = false
        if !active { status = "准备就绪" }
    }
    private var lastTranslationProgress = Date.distantPast
    private var translationWatchdogResets = 0
    private var lastPiPRegionWritten: CGRect?
    private var warmedPair = ""
    private var visionWarmed = false
    private var ocrReferenceVersion = 0
    private var inFlightTexts: Set<String> = []
    private var lastBatchKey = ""
    private var lastBatchAt = Date.distantPast
    private var lastScrollEstimateMs = 0
    private var scrollFramesTracked = 0
    private var scrollFramesUnknown = 0
    private var translationBatchLimit: Int {
        // Default 24 (was 5): one streamed batch per page instead of several
        // serial round trips; stale batches are cancelled when the page moves. `defaults write`-style override: UserDefaults key
        // "qingyiTranslateBatch" lets one build be A/B tested on a device.
        let value = UserDefaults.standard.integer(forKey: "qingyiTranslateBatch")
        return value > 0 ? min(value, 40) : 30
    }
    let pip = SubtitlePiP()

    init() {
        MLKitEngine.install()
        if let raw = UserDefaults.standard.string(forKey: "screenScope"),
           let saved = TranslationScope(rawValue: raw) { scope = saved }
        if let raw = UserDefaults.standard.string(forKey: "screenDisplayMode"),
           let saved = ScreenDisplayMode(rawValue: raw) { displayMode = saved }
        if let raw = UserDefaults.standard.string(forKey: "screenFixedRegion") {
            let saved = NSCoder.cgRect(for: raw)
            if saved.width >= 0.05 && saved.height >= 0.05,
               saved.minX >= 0 && saved.minY >= 0,
               saved.maxX <= 1 && saved.maxY <= 1 { fixedRegion = saved }
        }
        pip.renderScope = scope
        pip.renderFixedRegion = fixedRegion
        pip.renderMode = displayMode
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<ScreenModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in model.poll() }
        }, broadcastStoppedNotification as CFString, nil, .deliverImmediately)
    }

    /// Load the OCR and translation models while the user is still choosing to
    /// share the screen, so the first page is not also paying for model start-up.
    func prewarmPipeline() {
        let pair = "\(source.rawValue)|\(target.rawValue)"
        // Translation is not prewarmed: an extra session next to the batch
        // session added load on translationd. Only OCR and audio are warmed.
        warmedPair = pair
        pip.prewarmAudio()
        // Start (or confirm) the ML Kit offline model download for this pair.
        MLKitEngine.shared.prepare(source: source.code ?? "en", target: target.code ?? "zh-Hans")
        if !visionWarmed {
            visionWarmed = true
            Task.detached(priority: .utility) {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let sample = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 80), format: format).image { _ in
                    UIColor.white.setFill()
                    UIRectFill(CGRect(x: 0, y: 0, width: 320, height: 80))
                    ("Hello world" as NSString).draw(at: CGPoint(x: 12, y: 18), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.black])
                }
                _ = try? RecognitionService.recognize(sample)
            }
        }
    }

    func languagePairChanged() {
        translationTask?.cancel()
        translationSequence += 1
        pendingPageTexts = nil
        translationTask = nil
        failedTranslationKey = ""
        resultSignature = ""
        for index in blocks.indices { blocks[index].translated = "" }
        refreshTranslationText()
        if let latest { pip.show(image: latest, blocks: blocks) }
        scheduleTranslation()
        prewarmPipeline()
    }

    func setScope(_ value: TranslationScope) {
        scope = value
        pip.renderScope = value
        UserDefaults.standard.set(value.rawValue, forKey: "screenScope")
        translationTask?.cancel()
        translationSequence += 1
        pendingPageTexts = nil
        translationTask = nil
        generation += 1
        blocks = []
        original = ""
        translated = ""
        resultSignature = ""
        failedTranslationKey = ""
        forceOCR = true
        ocrReferenceProfile = []
        pip.overlayEstimate = .still
        status = active ? "范围已切换，正在重新识别" : "准备就绪"
        if let latest { pip.show(image: latest, blocks: []) }
    }

    func setFixedRegion(_ value: CGRect) {
        fixedRegion = value
        pip.renderFixedRegion = value
        UserDefaults.standard.set(NSCoder.string(for: value), forKey: "screenFixedRegion")
        if scope == .fixed {
            translationTask?.cancel()
            translationSequence += 1
            translationTask = nil
            generation += 1
            blocks = []
            original = ""
            translated = ""
            resultSignature = ""
            forceOCR = true
            ocrReferenceProfile = []
            pip.overlayEstimate = .still
            status = active ? "区域已更新，正在重新识别" : "准备就绪"
            if let latest { pip.show(image: latest, blocks: []) }
        }
    }

    func setDisplayMode(_ value: ScreenDisplayMode) {
        displayMode = value
        pip.renderMode = value
        UserDefaults.standard.set(value.rawValue, forKey: "screenDisplayMode")
        if let latest { pip.show(image: latest, blocks: blocks) }
    }

    func poll() {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup) else {
            status = "共享容器不可用，请检查 App Group 签名"; return
        }
        let state = (try? String(contentsOf: folder.appendingPathComponent("capture.state"), encoding: .utf8)) ?? ""
        defer { writeDebugTrace(captureState: state) }
        let running = state == "running"
        if broadcastRunning != running {
            broadcastRunning = running
            qyLog("capture state -> \(state.isEmpty ? "none" : state)")
        }
        if running && awaitingSystem { awaitingSystem = false }
        if awaitingSystem && Date().timeIntervalSince(awaitingSince) > 90 { cancelAwaitingSystem() }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("voice.mode").path) {
            if active { endSession(reason: "语音翻译正在使用屏幕共享") }
            else { status = "语音翻译正在使用屏幕共享" }
            return
        }
        if state == "stopped" {
            if active { endSession(reason: "屏幕共享已停止") }
            return
        }
        if state == "paused" { status = "屏幕共享已暂停"; return }
        guard state == "running" else { return }
        let frame = folder.appendingPathComponent("frame.jpg")
        if !active && !waitingAfterStall { status = "已授权，等待第一帧" }
        // Start PiP the moment the broadcast reports "running" instead of waiting
        // for the first JPEG: AVKit needs ~1-2 s to make PiP possible and start it,
        // and that now overlaps the extension's start-up. A stale "running" state
        // (extension killed without broadcastFinished) must not auto-open PiP.
        if !active && !pipPrestarted {
            let stateURL = folder.appendingPathComponent("capture.state")
            let stateAge = (try? stateURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            let frameAge = (try? frame.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if stateAge < 15 || frameAge < 3 {
                qyLog("broadcast running seen, stateAge=\(Int(stateAge * 1000))ms appState=\(UIApplication.shared.applicationState.rawValue)")
                pipPrestarted = true
                status = "正在开启画中画"
                prewarmPipeline()
                pip.beginSession(persistentRetries: true)
                pip.placeholderText = "正在开启屏幕翻译…"
                pip.show(image: nil, blocks: [])
                pip.ensureStarted()
            }
        } else if !active && pipPrestarted {
            // Retry while the first frame is still on its way (e.g. the system
            // broadcast sheet was still covering the app on the first attempt).
            pip.ensureStarted()
        }
        if !loadingPreview,
           let modified = try? frame.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified > lastFrameModified {
            loadingPreview = true
            lastFrameModified = modified
            let expected = generation
            // Both display modes carry the corner marks, so the PiP's own
            // window is found (and kept out of OCR) whatever is being shown.
            let lookForPiP = pip.isActuallyActive
            if !lookForPiP { pip.showsLocatorMarks = true }
            let marksShown = pip.showsLocatorMarks
            let knownRegion = pip.selfPiPRegion
            let renderedGrid = pip.lastRenderedGrid
            let currentVideoSize = pip.outputFrameSize
            let reference = (displayMode == .inPlace && !blocks.isEmpty) ? ocrReferenceProfile : []
            let referenceGeneration = ocrReferenceVersion
            Task { @MainActor [weak self] in
                let result = await Task.detached(priority: .userInitiated) { () -> (UIImage, CGRect?, Double?, ScrollEstimate?, Int)? in
                    guard let data = try? Data(contentsOf: frame), let image = UIImage(data: data) else { return nil }
                    // Detect the marker on the same frame that will be rendered.
                    // Using a previous frame's PiP rectangle leaves a moving copy
                    // of the PiP visible as it is dragged.
                    let region = lookForPiP && marksShown ? PiPRegionDetector.detect(in: image, videoSize: currentVideoSize) : nil
                    // With the marks hidden, check that the known PiP spot still
                    // shows our own frame; a large difference means it moved.
                    var mismatch: Double?
                    if lookForPiP, !marksShown, let knownRegion, renderedGrid.count == 72,
                       let cg = image.cgImage,
                       let crop = cg.cropping(to: CGRect(x: knownRegion.minX * CGFloat(cg.width),
                                                         y: knownRegion.minY * CGFloat(cg.height),
                                                         width: knownRegion.width * CGFloat(cg.width),
                                                         height: knownRegion.height * CGFloat(cg.height)).integral) {
                        let seen = FrameSignature.grid(UIImage(cgImage: crop), columns: 6, rows: 12)
                        if seen.count == 72 {
                            mismatch = Double(zip(seen, renderedGrid).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / 72
                        }
                    }
                    let started = Date()
                    let estimate = reference.isEmpty ? nil
                        : ScrollProfile.estimate(from: reference, to: ScrollProfile.make(image))
                    return (image, region, mismatch, estimate, Int(Date().timeIntervalSince(started) * 1000))
                }.value
                guard let self else { return }
                self.loadingPreview = false
                guard self.generation == expected, let (image, region, mismatch, estimate, estimateMs) = result else { return }
                // Ignore an estimate made against a reference that a newer OCR replaced.
                if let estimate, referenceGeneration == self.ocrReferenceVersion, !self.ocrReferenceProfile.isEmpty {
                    self.pip.overlayEstimate = estimate
                    self.lastScrollEstimateMs = estimateMs
                    if estimate.shift == nil { self.scrollFramesUnknown += 1 }
                    else if estimate.shift != 0 { self.scrollFramesTracked += 1 }
                }
                let currentState = (try? String(contentsOf: folder.appendingPathComponent("capture.state"), encoding: .utf8)) ?? ""
                guard currentState == "running" else { return }
                self.latest = image
                if lookForPiP {
                    if let mismatch {
                        if mismatch > 40 {
                            if self.pipMismatchSince == nil { self.pipMismatchSince = Date() }
                            if Date().timeIntervalSince(self.pipMismatchSince ?? Date()) > 0.6 {
                                // The window probably moved: show the marks again.
                                self.pip.showsLocatorMarks = true
                                self.pipMismatchSince = nil
                                self.lastPiPFound = Date()
                                qyLog("pip spot changed (diff \(Int(mismatch))), locating again")
                            }
                        } else {
                            self.pipMismatchSince = nil
                        }
                    }
                    if let region {
                        self.pip.selfPiPRegion = region
                        self.lastPiPFound = Date()
                        self.pipMismatchSince = nil
                    } else if Date().timeIntervalSince(self.lastPiPFound) > 2 {
                        // Keep covering the last known PiP spot through short
                        // misses (PiP controls dimming the marks, a blurred or
                        // tiny frame). Clearing it after 0.25 s let the
                        // PiP-inside-PiP flash back whenever one frame missed.
                        self.pip.selfPiPRegion = nil
                    }
                }
                if !self.active {
                    qyLog("first frame shown, age=\(Int(Date().timeIntervalSince(modified) * 1000))ms pipActive=\(self.pip.isActuallyActive)")
                    self.waitingAfterStall = false
                    self.active = true
                    self.status = "正在识别，准备画中画"
                    // Already begun when the broadcast reported "running"; beginning
                    // again would reset a PiP start that is in flight.
                    if !self.pipPrestarted { self.pip.beginSession(persistentRetries: true) }
                    self.pipPrestarted = true
                    self.prewarmPipeline()
                    let renderStart = Date()
                    self.pip.show(image: image, blocks: [])
                    self.lastRenderMs = Int(Date().timeIntervalSince(renderStart) * 1000)
                    self.pip.ensureStarted()
                } else if self.displayMode == .inPlace {
                    let renderStart = Date()
                    self.pip.show(image: image, blocks: self.blocks)
                    self.lastRenderMs = Int(Date().timeIntervalSince(renderStart) * 1000)
                }
                self.lastFramePresentMs = Int(Date().timeIntervalSince(modified) * 1000)
            }
        }
        let ocrFrame = folder.appendingPathComponent("ocr-frame.jpg")
        if active,
           let modified = try? ocrFrame.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified > lastOCRSeenModified {
            lastOCRSeenModified = modified
            ocrFramesSeen += 1
            if processingOCR { ocrFramesDroppedBusy += 1 }
        }
        if active, !processingOCR,
           let modified = try? ocrFrame.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified > lastOCRFrameModified,
           let data = try? Data(contentsOf: ocrFrame), let image = UIImage(data: data) {
            lastOCRFrameModified = modified
            currentOCRFrameTime = modified
            lastOCRFrameAgeMs = Int(Date().timeIntervalSince(modified) * 1000)
            startRecognition(image)
        }
        if active, translationTask != nil, Date().timeIntervalSince(lastTranslationProgress) > 12 {
            // Translation must never stall silently: drop the stuck batch and its
            // sessions, then schedule again from the current page.
            translationTask?.cancel()
            translationSequence += 1
            translationTask = nil
            inFlightTexts = []
            translationWatchdogResets += 1
            qyLog("translation watchdog reset")
            translator.resetSessions()
            translationStage = "翻译超时，已重试"
            scheduleTranslation()
        }
        if active, pip.isActuallyActive, pip.selfPiPRegion != lastPiPRegionWritten {
            // Tell the broadcast extension where our own PiP is so its motion
            // check ignores it (otherwise the PiP's own updates look like scrolling).
            lastPiPRegionWritten = pip.selfPiPRegion
            let text = pip.selfPiPRegion.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? ""
            try? text.write(to: folder.appendingPathComponent("pip-region.txt"), atomically: true, encoding: .utf8)
        }
        if active {
            if Date().timeIntervalSince(lastFrameModified) > 5 {
                status = "等待屏幕画面更新；可在系统面板检查共享状态"
            }
            pip.ensureStarted()
        }
    }

    private func endSession(reason: String) {
        translationRenderTask?.cancel()
        translationRenderTask = nil
        translationTask?.cancel()
        translationSequence += 1
        pendingPageTexts = nil
        translationTask = nil
        generation += 1
        resultSignature = ""
        failedTranslationKey = ""
        translationStage = "已停止"
        forceOCR = true
        lastOCRSignature = []
        ocrReferenceProfile = []
        inFlightTexts = []
        pipPrestarted = false
        pip.overlayEstimate = .still
        pip.stop()
        pip.selfPiPRegion = nil
        pip.showsLocatorMarks = true
        active = false
        latest = nil
        translated = ""
        original = ""
        blocks = []
        status = reason
    }

    func stopDisplay() {
        pip.stop()
        status = "画中画已关闭；屏幕共享仍由系统控制"
    }

    private func startRecognition(_ image: UIImage) {
        processingOCR = true
        let started = Date()
        let expected = generation
        let ownPiPRegion = pip.isActuallyActive ? pip.selfPiPRegion : nil
        let selectedScope = scope
        let selectedRegion = fixedRegion
        // Unchanged screens are re-OCR'd only after scope changes or every 6 s,
        // so completeness is kept while CPU/heat drop on static pages.
        let previousSignature = (forceOCR || Date().timeIntervalSince(lastOCRRanAt) > 6) ? [] : lastOCRSignature
        if translationTask == nil { status = "正在识别" }
        Task { @MainActor [weak self] in
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { () -> ([TextBlock], [UInt8], [UInt8])? in
                  try autoreleasepool {
                    let signature = FrameSignature.make(image)
                    if !previousSignature.isEmpty, FrameSignature.isSame(signature, previousSignature, excluding: ownPiPRegion) { return nil }
                    let lines = try RecognitionService.recognize(image)
                    let visibleLines = ownPiPRegion.map { mask in lines.filter { line in
                        let point = CGPoint(x: line.box.midX, y: 1 - line.box.midY)
                        return !mask.contains(point)
                    } } ?? lines
                    let scopedLines = visibleLines.filter { line in
                        let point = CGPoint(x: line.box.midX, y: 1 - line.box.midY)
                        return selectedScope.contains(point, fixedRegion: selectedRegion)
                    }
                    return (RecognitionService.mergeParagraphs(
                        RecognitionService.removeSmallerDuplicates(scopedLines)), signature,
                            ScrollProfile.make(image))
                  }
                }.value
                guard let self else { return }
                self.processingOCR = false
                guard self.active, self.generation == expected else { return }
                guard let (found, signature, profile) = outcome else {
                    self.ocrFramesSkippedStatic += 1
                    if self.translationTask == nil {
                        self.status = self.blocks.isEmpty ? "画面中没有识别到文字" : "翻译已更新"
                    }
                    return
                }
                self.lastOCRDurationMs = Int(Date().timeIntervalSince(started) * 1000)
                self.lastOCRSignature = signature
                self.lastOCRRanAt = Date()
                self.forceOCR = false
                self.ocrFramesProcessed += 1
                qyLog("ocr done \(self.lastOCRDurationMs)ms frameAge=\(self.lastOCRFrameAgeMs)ms blocks=\(found.count)")
                self.firstTranslationFromFrameMs = nil
                // New block coordinates belong to this OCR frame: reset tracking.
                self.ocrReferenceProfile = profile
                self.ocrReferenceVersion += 1
                self.pip.overlayEstimate = .still
                self.acceptRecognition(found)
            } catch {
                guard let self else { return }
                self.processingOCR = false
                if self.active { self.status = "识别失败：\(error.localizedDescription)" }
            }
        }
    }

    private func acceptRecognition(_ found: [TextBlock]) {
        lastResultModified = Date()
        let previousTexts = Set(blocks.map(\.original))
        let newTexts = Set(found.map(\.original))
        let newCount = newTexts.subtracting(previousTexts).count
        let changedPage = !newTexts.isEmpty && newCount >= 5
            && Double(newCount) / Double(newTexts.count) > 0.35
        // Never cancel a running Translation batch because the page moved.
        // Cancelling made every scroll abandon a batch and open a new session;
        // the flood of sessions crashed the system translation service
        // (translationd) on device. The running batch is small, finishes
        // quickly, and the next batch is taken from the page as it is now.
        _ = changedPage
        let signature = "\(source.rawValue)|\(target.rawValue)|" + found.map(\.original).joined(separator: "\u{1F}")
        resultSignature = signature
        let selected = source
        let selectedTarget = target
        blocks = found.map { block in
            var copy = block
            copy.translated = knownTranslations["\(selected.rawValue)|\(selectedTarget.rawValue)|\(block.original)"] ?? ""
            return copy
        }
        original = blocks.map(\.original).joined(separator: "\n")
        refreshTranslationText()
        if let latest { pip.show(image: latest, blocks: blocks) }
        guard !blocks.isEmpty else { status = "画面中没有识别到文字"; return }
        scheduleTranslation()
    }

    private func scheduleTranslationRender() {
        guard translationRenderTask == nil else { return }
        translationRenderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self else { return }
            self.translationRenderTask = nil
            guard !Task.isCancelled, self.active else { return }
            self.refreshTranslationText()
            if let latest = self.latest { self.pip.show(image: latest, blocks: self.blocks) }
        }
    }

    private func scheduleTranslation() {
        guard active, translationTask == nil else { return }
        let selected = source
        let selectedTarget = target
        var seen = Set<String>()
        let pending = Array(blocks.map(\.original).filter {
            seen.insert($0).inserted && knownTranslations["\(selected.rawValue)|\(selectedTarget.rawValue)|\($0)"] == nil
        }.prefix(translationBatchLimit))
        guard !pending.isEmpty else { status = "翻译已更新"; return }
        let key = "\(selected.rawValue)|\(selectedTarget.rawValue)|" + pending.joined(separator: "\u{1F}")
        guard key != failedTranslationKey || Date().timeIntervalSince(failedTranslationAt) > 5 else { return }
        // Safety net: the same texts must not be re-sent straight away.
        if key == lastBatchKey && Date().timeIntervalSince(lastBatchAt) < 2 { return }
        lastBatchKey = key
        lastBatchAt = Date()
        status = "正在翻译 0/\(pending.count)"
        translationStage = "开始批量翻译 \(pending.count) 块"
        translationStarted = Date()
        lastTranslationProgress = Date()
        firstTranslationMs = nil
        translationBatches += 1
        qyLog("translate batch start n=\(pending.count) source=\(selected.code ?? "auto")")
        inFlightTexts = Set(pending)
        translationSequence += 1
        let sequence = translationSequence
        // Highest priority: the XPC request to translationd inherits this QoS,
        // and while Qingyi sits in the background behind PiP it would otherwise
        // be served at a lowered priority.
        translationTask = Task(priority: .high) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.translationSequence == sequence {
                    self.translationTask = nil
                    self.inFlightTexts = []
                    if self.active { self.scheduleTranslation() }
                }
            }
            var completed = 0
            do {
                try await self.translator.translateBatch(pending, source: selected, target: selectedTarget, receive: { index, value in
                    guard !Task.isCancelled, self.active, self.translationSequence == sequence,
                          self.source == selected, self.target == selectedTarget,
                          pending.indices.contains(index) else { return }
                    let text = pending[index]
                    if self.firstTranslationMs == nil {
                        self.firstTranslationMs = Int(Date().timeIntervalSince(self.translationStarted) * 1000)
                    }
                    if self.firstTranslationFromFrameMs == nil {
                        self.firstTranslationFromFrameMs = Int(Date().timeIntervalSince(self.currentOCRFrameTime) * 1000)
                        qyLog("first translation \(self.firstTranslationMs ?? -1)ms after batch start, \(self.firstTranslationFromFrameMs ?? -1)ms after frame")
                    }
                    if self.knownTranslations.count >= 800 {
                        // Keep only this page's translations. Evicting one
                        // arbitrary key per insert let two texts of the same
                        // batch evict each other, so the batch was retried
                        // forever (every ~8 ms) and froze the PiP.
                        let prefix = "\(selected.rawValue)|\(selectedTarget.rawValue)|"
                        let onPage = Set(self.blocks.map { prefix + $0.original })
                        self.knownTranslations = self.knownTranslations.filter { onPage.contains($0.key) }
                    }
                    self.knownTranslations["\(selected.rawValue)|\(selectedTarget.rawValue)|\(text)"] = value
                    for blockIndex in self.blocks.indices where self.blocks[blockIndex].original == text {
                        self.blocks[blockIndex].translated = value
                    }
                    completed += 1
                    self.lastTranslationProgress = Date()
                    self.status = "正在翻译 \(completed)/\(pending.count)"
                    self.scheduleTranslationRender()
                }, progress: { stage in
                    self.translationStage = stage
                    if stage.hasPrefix("合并") { qyLog(stage) }
                })
                guard !Task.isCancelled, self.active, self.source == selected else { return }
                self.status = "翻译已更新"
                self.lastTranslationTotalMs = Int(Date().timeIntervalSince(self.translationStarted) * 1000)
                qyLog("translate batch done \(completed)/\(pending.count) in \(self.lastTranslationTotalMs)ms")
                self.translationStage = "完成 \(completed)/\(pending.count)"
            } catch {
                guard !Task.isCancelled, self.active else { return }
                self.failedTranslationKey = key
                self.failedTranslationAt = Date()
                qyLog("translate batch failed: \(error.localizedDescription)")
                self.status = "翻译失败：\(error.localizedDescription)"
                self.translationStage = self.status
            }
        }
    }

    private func refreshTranslationText() {
        translated = blocks.map { $0.translated.isEmpty ? $0.original : $0.translated }.joined(separator: "\n")
    }

    private func writeDebugTrace(captureState: String) {
        #if DEBUG
        guard Date().timeIntervalSince(lastDebugTrace) >= 1 else { return }
        lastDebugTrace = Date()
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let trace = "time=\(ISO8601DateFormatter().string(from: Date()))\n"
            + "broadcast=\(captureState)\nactive=\(active)\n"
            + "frameTime=\(lastFrameModified)\nresultTime=\(lastResultModified)\n"
            + "frameAgeAtPresentationMs=\(lastFramePresentMs)\nrenderMs=\(lastRenderMs)\n"
            + "ocrMs=\(lastOCRDurationMs)\nfirstTranslationMs=\(firstTranslationMs.map(String.init) ?? "pending")\n"
            + "ocrFrameAgeAtStartMs=\(lastOCRFrameAgeMs)\nframeToFirstTranslationMs=\(firstTranslationFromFrameMs.map(String.init) ?? "pending")\n"
            + "lastBatchTotalMs=\(lastTranslationTotalMs)\nbatchLimit=\(translationBatchLimit)\nbatches=\(translationBatches)\n"
            + "ocrFramesSeen=\(ocrFramesSeen)\nocrFramesProcessed=\(ocrFramesProcessed)\n"
            + "ocrFramesDroppedBusy=\(ocrFramesDroppedBusy)\nocrFramesSkippedStatic=\(ocrFramesSkippedStatic)\n"
            + "thermal=\(ProcessInfo.processInfo.thermalState.rawValue)\n"
            + "watchdogResets=\(translationWatchdogResets)\n"
            + "pipStartLatencyMs=\(pip.startLatencyMs.map(String.init) ?? "pending")\n"
            + "scrollEstimateMs=\(lastScrollEstimateMs)\nscrollFramesTracked=\(scrollFramesTracked)\nscrollFramesUnknown=\(scrollFramesUnknown)\n"
            + "frameSize=\(latest?.size.width ?? 0)x\(latest?.size.height ?? 0)\n"
            + "blocks=\(blocks.count)\ntranslatedBlocks=\(blocks.filter { !$0.translated.isEmpty && $0.translated != $0.original }.count)\n"
            + "status=\(status)\npip=\(pip.state)\n"
            + "pipActuallyActive=\(pip.isActuallyActive)\npipPossible=\(pip.isPossible)\n"
            + "pipRegion=\(pip.selfPiPRegion.map(String.init(describing:)) ?? "none")\n"
            + "pipVideoSize=\(Int(pip.outputFrameSize.width))x\(Int(pip.outputFrameSize.height))\n"
            + "translationStage=\(translationStage)\n"
            + "scope=\(scope.rawValue)\n"
            + "translationElapsed=\(translationStarted == .distantPast ? 0 : Int(Date().timeIntervalSince(translationStarted)))s\n"
            + "applicationState=\(UIApplication.shared.applicationState.rawValue)\n"
        try? trace.write(to: documents.appendingPathComponent("screen-trace.txt"), atomically: true, encoding: .utf8)
        #endif
    }
}

struct ScreenHome: View {
    @StateObject private var installedLanguages = InstalledLanguageOptions()
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @ObservedObject var model: ScreenModel
    @ObservedObject var lens: LensModel
    @State private var showFrozen = false
    @State private var showLivePreview = false
    @State private var showScope = false
    @State private var showDisplayMode = false
    @State private var showGuide = false
    @State private var continueAfterGuide = false
    @State private var pickerTrigger = 0
    @AppStorage("screenStartGuideHidden") private var guideHidden = false
    @State private var showMistHelp = false
    private let ticker = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    private func startTapped() {
        if guideHidden { openSystemPicker() } else { showGuide = true }
    }

    private func openSystemPicker() {
        model.beginAwaitingSystem()
        pickerTrigger += 1
    }

    var body: some View {
        Group {
        if visualTheme == 5 { mistLayout } else if visualTheme == 4 { nativeThemeLayout } else if visualTheme == 3 { themeFourLayout } else if visualTheme == 2 { themeThreeLayout } else if visualTheme == 1 { warmLayout } else {
        ScrollView {
            VStack(spacing: 17) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Circle().fill(model.active ? Color.green : Color(red: 0.27, green: 0.42, blue: 0.33))
                            .frame(width: 10, height: 10)
                            .shadow(color: .green.opacity(0.45), radius: 5)
                        Text(model.status).font(.system(size: 26, weight: .light, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    Text(model.active ? "切换到其他 App，在画中画里查看译文。" : "授权屏幕共享后，画中画会在其他 App 上方显示翻译。")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.88))
                    PiPSourceView(controller: model.pip)
                        .frame(width: model.pip.previewSize.width,
                               height: model.pip.previewSize.height)
                        .background(.black, in: RoundedRectangle(cornerRadius: 30))
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                        .frame(maxWidth: .infinity)
                }
                .padding(18)
                .clearGlass(30)

                VStack(spacing: 0) {
                    HStack {
                        Label("原文语言", systemImage: "globe")
                        Spacer()
                        Picker("原文", selection: $model.source) {
                            ForEach(installedLanguages.sourceOptions(current: model.source, auto: true)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled($0 != .auto && !installedLanguages.sources.contains($0)) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    .padding(16)
                    Divider().padding(.leading, 16)
                    HStack {
                        Label("译成", systemImage: "translate")
                        Spacer()
                        Picker("译文", selection: $model.target) {
                            ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    .padding(16)
                    Divider().padding(.leading, 16)
                    Button { showScope = true } label: {
                        HStack {
                            Label("翻译范围", systemImage: "viewfinder")
                            Spacer()
                            Text(model.scope.rawValue).foregroundStyle(.white.opacity(0.88))
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.7))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(16)
                    Divider().padding(.leading, 16)
                    Button { showDisplayMode = true } label: {
                        HStack {
                            Label("显示方式", systemImage: "rectangle.on.rectangle")
                            Spacer()
                            Text(model.displayMode.rawValue).foregroundStyle(.white.opacity(0.88))
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.7))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(16)
                }
                .clearGlass(24)
                .onChange(of: model.target) { _, _ in model.languagePairChanged() }
                .onChange(of: model.source) { _, selected in
                    UserDefaults(suiteName: sharedGroup)?.set(selected.rawValue, forKey: "screenSource")
                    model.languagePairChanged()
                }

                TranslationReadinessView(source: model.source, target: model.target)

                HStack(spacing: 16) {
                    BroadcastPicker(onTap: { model.beginAwaitingSystem() })
                        .frame(width: 62, height: 62)
                        .clearGlass(31)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开启翻译").font(.title3.bold())
                        Text("点左侧系统按钮授权屏幕共享")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.88))
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .foregroundStyle(.white)
                .clearGlass(25)
                .shadow(color: .green.opacity(0.22), radius: 10, y: 5)
                Text("选择「青译屏幕采集」后等待小窗出现，再进入目标 App。")
                    .font(.caption).foregroundStyle(.white.opacity(0.88))
                if model.active {
                    HStack {
                        Button("重新开启画中画") { model.pip.start() }
                        Spacer()
                        Button("定格到智能镜头") {
                            if let image = model.latest { lens.load(image); showFrozen = true }
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(12)
                    .clearGlass(18)
                }
                if !model.translated.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最新译文").font(.caption).foregroundStyle(.white.opacity(0.88))
                        Text(model.translated).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        .clearGlass(18)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("画中画状态").font(.headline)
                        PiPStatusView(pip: model.pip)
                        if model.active {
                            Button("关闭画中画") { model.stopDisplay() }
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                }.padding().clearGlass(18)
                Text("结束采集请在 iOS 屏幕共享面板中停止「青译屏幕采集」。屏幕内容只在本机处理。")
                    .font(.footnote).foregroundStyle(.white.opacity(0.88))
            }.padding().foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        }
        } }
        .onChange(of: model.target) { _, _ in if visualTheme != 0 { model.languagePairChanged() } }
        .onChange(of: model.source) { _, selected in
            if visualTheme != 0 {
                UserDefaults(suiteName: sharedGroup)?.set(selected.rawValue, forKey: "screenSource")
                model.languagePairChanged()
            }
        }
        .task(id: "\(model.source.rawValue)|\(model.target.rawValue)") { await installedLanguages.refresh(source: model.source, target: model.target, speech: false) }
        .onReceive(NotificationCenter.default.publisher(for: .init("QingyiLanguagePacksChanged"))) { _ in Task { await installedLanguages.refresh(source: model.source, target: model.target, speech: false) } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await installedLanguages.refresh(source: model.source, target: model.target, speech: false) } }
        .onAppear {
            if (visualTheme == 4 || visualTheme == 5) && model.scope == .nearby { model.setScope(.fullScreen) }
            model.poll()
            // Rendering the PiP placeholder and warming the pipeline are
            // deferred so switching to this tab animates smoothly.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                if !model.active { model.pip.show(image: nil, blocks: []) }
                model.prewarmPipeline()
            }
        }
        .onReceive(ticker) { _ in model.poll() }
        .fullScreenCover(isPresented: $showFrozen) { LensView(model: lens, onClose: { showFrozen = false }) }
        .onReceive(NotificationCenter.default.publisher(for: .init("QingyiLanguagePacksChanged"))) { _ in model.languagePairChanged() }
        .sheet(isPresented: $showScope) { ScreenScopeSheet(model: model) }
        .sheet(isPresented: $showDisplayMode) { ScreenDisplayModeSheet(model: model) }
        .background(alignment: .topLeading) {
            HiddenBroadcastPicker(trigger: pickerTrigger).frame(width: 4, height: 4)
        }
        .sheet(isPresented: $showGuide, onDismiss: {
            if continueAfterGuide { continueAfterGuide = false; openSystemPicker() }
        }) {
            BroadcastGuideSheet(
                title: "三步开始屏幕翻译",
                subtitle: "青译翻译会识别整个屏幕，把译文放进一个可以随处拖动的小窗。",
                steps: [(icon: "hand.tap", text: "点下方「继续」，打开系统的屏幕共享面板"),
                        (icon: "record.circle", text: "在面板里点「开始直播」"),
                        (icon: "pip", text: "小窗弹出后，切到要看的 App；小窗可拖动、双指缩放")],
                note: "屏幕内容只在这台手机上识别和翻译，不会上传。",
                onContinue: { continueAfterGuide = true; showGuide = false },
                onNeverShow: { guideHidden = true; continueAfterGuide = true; showGuide = false })
        }
        .sheet(isPresented: $showMistHelp) {
            MistHelpSheet(title: "屏幕翻译怎么用", lines: [
                "在卡片里选好原文和要译成的语言。",
                "点「开启翻译」，在系统面板里点「开始直播」。",
                "留在本页，小窗弹出后再切到要看的 App。",
                "上方的圆角卡片可以切换翻译范围；右上角调整显示方式。",
                "用完点「停止翻译」，在系统面板里停止。"])
        }
    }
    // MARK: 雾面

    private var mistLayout: some View {
        let phase = ScreenPhase.of(model, model.pip)
        let translatedCount = model.blocks.filter { !$0.translated.isEmpty && $0.translated != $0.original }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MistTopBar(title: "屏幕翻译") {
                    if model.active {
                        MistCircleButton(systemImage: "camera.viewfinder", label: "定格到智能镜头") {
                            if let image = model.latest { lens.load(image); showFrozen = true }
                        }
                    } else {
                        MistCircleButton(systemImage: "questionmark", label: "使用说明") { showMistHelp = true }
                    }
                } right: {
                    MistCircleButton(systemImage: "slider.horizontal.3", label: "翻译范围与区域") { showScope = true }
                }
                HStack(spacing: 10) {
                    MistSegment(caption: "翻译范围",
                                options: [(value: TranslationScope.fullScreen, icon: "iphone", title: "全屏"),
                                          (value: TranslationScope.fixed, icon: "viewfinder", title: "区域")],
                                selection: model.scope == .fixed ? .fixed : .fullScreen) { value in
                        if value == .fixed { showScope = true } else { model.setScope(.fullScreen) }
                    }
                    MistSegment(caption: "译文显示",
                                options: [(value: ScreenDisplayMode.inPlace, icon: "text.below.photo", title: "原位"),
                                          (value: ScreenDisplayMode.subtitles, icon: "captions.bubble", title: "字幕")],
                                selection: model.displayMode) { model.setDisplayMode($0) }
                }

                VStack(alignment: .leading, spacing: 12) {
                    MistCardHeader(title: "实时屏幕翻译", actionTitle: showLivePreview ? "收起画面" : "画面") {
                        withAnimation { showLivePreview.toggle() }
                    }
                    HStack(alignment: .center) {
                        MistBigValue(value: model.source.mistCode, suffix: "→ \(model.target.rawValue)")
                        Spacer(minLength: 8)
                        VStack(alignment: .leading, spacing: 10) {
                            MistStat(fraction: model.blocks.isEmpty ? 0 : 1, text: "\(model.blocks.count) 段")
                            MistStat(fraction: model.blocks.isEmpty ? 0 : Double(translatedCount) / Double(max(1, model.blocks.count)),
                                     text: "\(translatedCount) 译", dim: true)
                        }
                    }
                    MistArcGauge(labels: ["准备", "系统确认", "开启小窗", "翻译中"],
                                 progress: phase.progress,
                                 active: phase == .running || phase == .starting,
                                 level: min(1, Double(model.blocks.count) / 30))
                        .equatable()
                        .padding(.horizontal, -22)
                    MistInsight(title: phase.title, detail: phase.detail)
                    switch phase {
                    case .idle:
                        MistPrimaryButton(title: "开启翻译", systemImage: "play.fill", action: startTapped)
                    case .waiting:
                        HStack(spacing: 10) {
                            MistPrimaryButton(title: "取消", systemImage: "xmark", quiet: true) { model.cancelAwaitingSystem() }
                                .frame(width: 120)
                            MistPrimaryButton(title: "重新打开面板", systemImage: "record.circle", action: startTapped)
                        }
                    case .starting, .running:
                        MistPrimaryButton(title: "停止翻译", systemImage: "stop.fill", quiet: true) { pickerTrigger += 1 }
                    case .pipClosed:
                        HStack(spacing: 10) {
                            MistPrimaryButton(title: "停止", systemImage: "stop.fill", quiet: true) { pickerTrigger += 1 }
                                .frame(width: 120)
                            MistPrimaryButton(title: "重开小窗", systemImage: "pip.enter") { model.pip.start() }
                        }
                    }
                    HStack(spacing: 10) {
                        Menu {
                            Picker("原文", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: true)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled($0 != .auto && !installedLanguages.sources.contains($0)) } }
                        } label: { MistMenuLabel(title: "原文", value: model.source.rawValue) }
                        Menu {
                            Picker("译成", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }
                        } label: { MistMenuLabel(title: "译成", value: model.target.rawValue) }
                    }
                    TranslationReadinessView(source: model.source, target: model.target)
                        .foregroundStyle(Mist.inkSoft).lineLimit(1)
                    // The PiP source must stay in the window; 「画面」 shows it
                    // at full card width, otherwise it is kept at 1 pt.
                    PiPLivePreview(pip: model.pip, expanded: showLivePreview)
                        .padding(.top, showLivePreview ? 0 : -12)
                }
                .mistCard()
            }
            .padding(.horizontal, 18).padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.colorScheme, .light)
    }

    private var nativeThemeLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("屏幕翻译").font(.largeTitle.bold()).padding(.top, 12)
                ScreenStatusHero(model: model, pip: model.pip,
                                 onStart: startTapped,
                                 onStop: { pickerTrigger += 1 })
                    .padding(18).nativeThemeCard()
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text("原文语言").font(.subheadline.bold()); Spacer(); Picker("原文", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: true)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled($0 != .auto && !installedLanguages.sources.contains($0)) } }.labelsHidden() }.padding(18)
                    Divider().padding(.horizontal, 18)
                    HStack { Text("译成").font(.subheadline.bold()); Spacer(); Picker("译文", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }.labelsHidden().tint(.cyan) }.padding(18)
                    Divider().padding(.horizontal, 18)
                    Button { showScope = true } label: { HStack { Text("翻译范围"); Spacer(); Text(model.scope.rawValue).foregroundStyle(.secondary); Image(systemName: "chevron.right") }.padding(18).contentShape(Rectangle()) }.buttonStyle(.plain)
                }.nativeThemeCard()
                TranslationReadinessView(source: model.source, target: model.target)
                VStack(alignment: .leading, spacing: 10) {
                    Button { withAnimation { showLivePreview.toggle() } } label: {
                        HStack { Text("实时画面").font(.headline); Spacer(); Text(model.status).font(.caption).foregroundStyle(.secondary); Image(systemName: showLivePreview ? "chevron.up" : "chevron.down").foregroundStyle(.secondary) }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(showLivePreview ? "已展开" : "已折叠")
                    PiPLivePreview(pip: model.pip, expanded: showLivePreview, cornerRadius: 20)
                }.padding(18).nativeThemeCard()
                if model.active { Button { if let image = model.latest { lens.load(image); showFrozen = true } } label: { Label("定格到智能镜头", systemImage: "camera.viewfinder").frame(maxWidth: .infinity, alignment: .leading).padding(18).contentShape(Rectangle()) }.buttonStyle(.plain).nativeThemeCard() }
                if !model.translated.isEmpty { VStack(alignment: .leading) { Text("最新译文").font(.caption).foregroundStyle(.secondary); Text(model.translated).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).nativeThemeCard() }
                DisclosureGroup("使用说明") {
                    Text("1. 选择原文和目标语言。\n2. 点「开启翻译」，在系统面板里点「开始直播」。\n3. 留在青译，等画中画小窗弹出后再切换到其他 App。\n4. 用完点「停止翻译」，在系统面板里停止。")
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.padding(18).nativeThemeCard()
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }

    }
    private var themeFourLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text("你好，欢迎使用").font(.caption).foregroundStyle(.secondary); Text("屏幕翻译").font(.system(size: 27, weight: .bold)) }; Spacer(); Image(systemName: "viewfinder").font(.title3).frame(width: 50, height: 50).background(Color(red: 0.78, green: 0.71, blue: 0.91), in: Circle()).foregroundStyle(.black) }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) { Text("开启翻译").font(.title2.bold()); Text(model.status).font(.subheadline); Text("屏幕文字，随时看懂").font(.caption) ; Spacer(minLength: 8); BroadcastPicker(onTap: { model.beginAwaitingSystem() }).frame(width: 55, height: 55).background(.white.opacity(0.75), in: Circle()) }
                    Spacer()
                    PiPSourceView(controller: model.pip).frame(width: min(model.pip.previewSize.width, 115), height: min(model.pip.previewSize.height, 200)).background(.black, in: RoundedRectangle(cornerRadius: 18)).clipShape(RoundedRectangle(cornerRadius: 18))
                }.padding(20).foregroundStyle(.black).frame(maxWidth: .infinity, alignment: .leading).themeFourCard(Color(red: 0.86, green: 0.64, blue: 0.92))
                HStack { Text("翻译设置").font(.title3.bold()); Spacer(); TranslationReadinessView(source: model.source, target: model.target).font(.caption) }
                VStack(spacing: 0) {
                    HStack { Label("原文语言", systemImage: "globe"); Spacer(); Picker("原文", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: true)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled($0 != .auto && !installedLanguages.sources.contains($0)) } }.labelsHidden() }.padding(16)
                    Divider().padding(.horizontal, 16)
                    HStack { Label("翻译成", systemImage: "translate"); Spacer(); Picker("译文", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }.labelsHidden() }.padding(16)
                }.themeFourCard()
                HStack(spacing: 12) {
                    Button { showScope = true } label: { VStack(alignment: .leading, spacing: 10) { Image(systemName: "viewfinder").font(.title3); Text("翻译范围").font(.headline); Text(model.scope.rawValue).font(.caption); HStack { Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.white).padding(10).background(.black, in: Circle()) } }.frame(maxWidth: .infinity, alignment: .leading).padding(15).foregroundStyle(.black).themeFourCard(Color(red: 0.78, green: 0.71, blue: 0.91)) }.buttonStyle(.plain)
                    Button { showDisplayMode = true } label: { VStack(alignment: .leading, spacing: 10) { Image(systemName: "rectangle.on.rectangle").font(.title3); Text("显示方式").font(.headline); Text(model.displayMode.rawValue).font(.caption); HStack { Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.white).padding(10).background(.black, in: Circle()) } }.frame(maxWidth: .infinity, alignment: .leading).padding(15).foregroundStyle(.black).themeFourCard(Color(red: 1, green: 0.92, blue: 0.58)) }.buttonStyle(.plain)
                }
                if model.active { HStack { Button("重新开启画中画") { model.pip.start() }; Spacer(); Button("定格到智能镜头") { if let image = model.latest { lens.load(image); showFrozen = true } } }.padding(16).themeFourCard() }
                if !model.translated.isEmpty { VStack(alignment: .leading) { Text("最新译文").font(.caption).foregroundStyle(.secondary); Text(model.translated).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).themeFourCard() }
                HStack { VStack(alignment: .leading) { Text("画中画状态").font(.headline); PiPStatusView(pip: model.pip); if model.active { Button("关闭画中画") { model.stopDisplay() }.font(.caption) } }; Spacer() }.padding(18).themeFourCard()
                Text("结束采集请在系统屏幕共享面板中停止。") .font(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
    private var themeThreeLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) { Text("屏幕翻译").font(.system(size: 28, weight: .medium, design: .rounded)); Text("在其他 App 中查看译文").font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    Image(systemName: "viewfinder").font(.title3).frame(width: 48, height: 48).background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                }.padding(.top, 8)
                VStack(alignment: .leading, spacing: 12) {
                    HStack { VStack(alignment: .leading, spacing: 5) { Text("实时画面").font(.headline); Text(model.status).font(.caption).opacity(0.85) }; Spacer(); Circle().fill(model.active ? .green : .white.opacity(0.65)).frame(width: 8, height: 8) }
                    PiPSourceView(controller: model.pip).frame(width: model.pip.previewSize.width, height: model.pip.previewSize.height).background(.black, in: RoundedRectangle(cornerRadius: 26)).clipShape(RoundedRectangle(cornerRadius: 26)).frame(maxWidth: .infinity)
                }.padding(20).foregroundStyle(.white).themeThreeCard(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("翻译设置").font(.headline).padding([.horizontal, .top], 18)
                    HStack { Text("原文语言"); Spacer(); Picker("原文", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: true)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled($0 != .auto && !installedLanguages.sources.contains($0)) } }.labelsHidden() }.padding(16)
                    Divider().padding(.horizontal, 16)
                    HStack { Text("译成"); Spacer(); Picker("译文", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }.labelsHidden() }.padding(16)
                    Divider().padding(.horizontal, 16)
                    Button { showScope = true } label: { HStack { Text("翻译范围"); Spacer(); Text(model.scope.rawValue).foregroundStyle(.secondary); Image(systemName: "chevron.right") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain)
                    Divider().padding(.horizontal, 16)
                    Button { showDisplayMode = true } label: { HStack { Text("显示方式"); Spacer(); Text(model.displayMode.rawValue).foregroundStyle(.secondary); Image(systemName: "chevron.right") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain)
                }.themeThreeCard()
                TranslationReadinessView(source: model.source, target: model.target)
                HStack(spacing: 14) {
                    BroadcastPicker(onTap: { model.beginAwaitingSystem() }).frame(width: 55, height: 55)
                    VStack(alignment: .leading, spacing: 3) { Text("开启翻译").font(.headline); Text("点击左侧按钮授权屏幕共享").font(.caption).foregroundStyle(.secondary) }; Spacer()
                }.padding(15).themeThreeCard()
                if model.active { HStack { Button("重新开启画中画") { model.pip.start() }; Spacer(); Button("定格到智能镜头") { if let image = model.latest { lens.load(image); showFrozen = true } } }.padding(18).themeThreeCard() }
                if !model.translated.isEmpty { VStack(alignment: .leading) { Text("最新译文").font(.caption).foregroundStyle(.secondary); Text(model.translated).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).themeThreeCard() }
                HStack { VStack(alignment: .leading) { Text("画中画状态").font(.headline); PiPStatusView(pip: model.pip); if model.active { Button("关闭画中画") { model.stopDisplay() }.font(.caption) } }; Spacer() }.padding(18).themeThreeCard()
                Text("结束采集请在 iOS 屏幕共享面板中停止「青译屏幕采集」。").font(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 30)
        }
    }
    private var warmLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "viewfinder").font(.title3).padding(12).clearGlass(25)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("屏幕翻译").font(.headline)
                        Text(model.status).font(.caption).opacity(0.8)
                    }
                    Spacer()
                    Circle().fill(model.active ? .green : .white.opacity(0.5)).frame(width: 8, height: 8)
                }.padding(18).clearGlass(28)
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("实时画面").font(.headline); Spacer(); Text(model.active ? "正在识别" : "等待共享").font(.caption).opacity(0.75) }
                    PiPSourceView(controller: model.pip)
                        .frame(width: model.pip.previewSize.width, height: model.pip.previewSize.height)
                        .background(.black, in: RoundedRectangle(cornerRadius: 24))
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .frame(maxWidth: .infinity)
                }.padding(20).clearGlass(28)
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "globe").frame(width: 28)
                        Text("原文语言"); Spacer()
                        Picker("原文", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: true)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled($0 != .auto && !installedLanguages.sources.contains($0)) } }.labelsHidden()
                    }.padding(16)
                    Divider().overlay(.white.opacity(0.15))
                    HStack {
                        Image(systemName: "translate").frame(width: 28)
                        Text("翻译成"); Spacer()
                        Picker("译文", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }.labelsHidden()
                    }.padding(16)
                    Divider().overlay(.white.opacity(0.15))
                    Button { showScope = true } label: { HStack { Label("翻译范围", systemImage: "viewfinder"); Spacer(); Text(model.scope.rawValue).opacity(0.8); Image(systemName: "chevron.right") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.15))
                    Button { showDisplayMode = true } label: { HStack { Label("显示方式", systemImage: "rectangle.on.rectangle"); Spacer(); Text(model.displayMode.rawValue).opacity(0.8); Image(systemName: "chevron.right") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain)
                }.clearGlass(26)
                TranslationReadinessView(source: model.source, target: model.target)
                HStack(spacing: 14) {
                    BroadcastPicker(onTap: { model.beginAwaitingSystem() }).frame(width: 56, height: 56).clearGlass(28)
                    VStack(alignment: .leading, spacing: 4) { Text("开启翻译").font(.headline); Text("点击左侧按钮，按系统提示开始共享").font(.caption).opacity(0.8) }
                    Spacer()
                }.padding(14).background(Color(red: 0.9, green: 0.36, blue: 0.31).opacity(0.34), in: RoundedRectangle(cornerRadius: 26)).clearGlass(26)
                if model.active {
                    HStack {
                        Button("重新开启画中画") { model.pip.start() }
                        Spacer()
                        Button("定格到智能镜头") { if let image = model.latest { lens.load(image); showFrozen = true } }
                    }.padding(16).clearGlass(22)
                }
                if !model.translated.isEmpty {
                    VStack(alignment: .leading, spacing: 6) { Text("最新译文").font(.caption).opacity(0.8); Text(model.translated).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).clearGlass(24)
                }
                HStack { VStack(alignment: .leading) { Text("画中画状态").font(.headline); PiPStatusView(pip: model.pip); if model.active { Button("关闭画中画") { model.stopDisplay() }.font(.caption) } }; Spacer() }.padding(18).clearGlass(24)
                Text("结束采集请在 iOS 屏幕共享面板中停止「青译屏幕采集」。屏幕内容只在本机处理。").font(.footnote).opacity(0.8)
            }.padding(.horizontal, 20).padding(.bottom, 24).foregroundStyle(.white)
        }
    }
}

private struct ScreenDisplayModeSheet: View {
    @ObservedObject var model: ScreenModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ForEach(ScreenDisplayMode.allCases) { option in
                    Button {
                        model.setDisplayMode(option)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: option == .inPlace ? "text.viewfinder" : "captions.bubble")
                                .font(.title2).frame(width: 36)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(option.rawValue).font(.headline)
                                Text(option.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: model.displayMode == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.displayMode == option ? .green : .secondary)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clearGlass(20)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding()
            .background(GlassWallpaper())
            .navigationTitle("显示方式")
            .mistSheet()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium])
    }
}

struct PiPStatusView: View {
    @ObservedObject var pip: SubtitlePiP
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pip.state)
            Text(pip.state == "画中画正在显示" ? "小窗已出现，可以切换到其他 App。" : "开启共享后请留在本页，等小窗出现再切换 App。")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct ScreenScopeSheet: View {
    @ObservedObject var model: ScreenModel
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(TranslationScope.allCases.filter { $0 != .nearby }) { option in
                        Button {
                            model.setScope(option)
                            if option == .fixed { detent = .large }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option == .fullScreen ? "rectangle.dashed" :
                                        option == .fixed ? "crop" : "rectangle.on.rectangle")
                                    .font(.title3)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.rawValue).font(.headline)
                                    Text(option.description).font(.footnote).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: model.scope == option ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.scope == option ? .green : .secondary)
                            }
                            .padding(15)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clearGlass(18)
                        }
                        .buttonStyle(.plain)
                    }
                    if model.scope == .fixed {
                        Text("在画面上拖动，框出只需翻译的区域")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        FixedRegionEditor(model: model)
                    }
                }
                .padding()
            }
            .background(GlassWallpaper())
            .navigationTitle("翻译范围")
            .mistSheet()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onAppear { if model.scope == .fixed { detent = .large } }
    }
}

private struct FixedRegionEditor: View {
    @ObservedObject var model: ScreenModel
    @State private var dragStart: CGPoint?
    @State private var draft: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let canvas = CGRect(origin: .zero, size: geometry.size)
            let imageRect = fittedRect(imageSize: model.latest?.size ?? CGSize(width: 360, height: 780),
                                       in: canvas)
            let region = draft ?? model.fixedRegion
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.1))
                if let image = model.latest {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                } else {
                    Text("开启屏幕共享后可按实时画面框选\n也可以先预设位置")
                        .font(.caption).multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                Rectangle()
                    .fill(Color.green.opacity(0.16))
                    .overlay(Rectangle().strokeBorder(.green, lineWidth: 2))
                    .frame(width: region.width * imageRect.width,
                           height: region.height * imageRect.height)
                    .position(x: imageRect.minX + region.midX * imageRect.width,
                              y: imageRect.minY + region.midY * imageRect.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let point = normalized(value.location, in: imageRect)
                    if dragStart == nil { dragStart = point }
                    if let start = dragStart {
                        draft = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                       width: abs(point.x - start.x), height: abs(point.y - start.y))
                    }
                }
                .onEnded { _ in
                    if let draft, draft.width >= 0.05, draft.height >= 0.05 {
                        model.setFixedRegion(draft)
                    }
                    dragStart = nil
                    draft = nil
                })
        }
        .frame(width: 230, height: 500)
        .frame(maxWidth: .infinity)
    }

    private func fittedRect(imageSize: CGSize, in canvas: CGRect) -> CGRect {
        let scale = min(canvas.width / max(1, imageSize.width),
                        canvas.height / max(1, imageSize.height))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
                y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height))))
    }
}

final class SampleVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }
}

@MainActor final class SubtitlePiP: NSObject, ObservableObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    @Published var state = "等待屏幕共享"
    let view = SampleVideoView()
    private var controller: AVPictureInPictureController?
    private let context = CIContext()
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var autoStartEnabled = false
    private var startAttempts = 0
    private var persistentStartRetries = false
    private var awaitingStopCallback = false
    private var lastStartAttempt = Date.distantPast
    private var startRequestedAt = Date.distantPast
    private var startPending = false
    private var closing = false
    private var overlaySignature = ""
    private var overlayDrawnAt = Date.distantPast
    private var overlay: CIImage?
    private var topOverlay: CIImage?
    private var bottomOverlay: CIImage?
    /// Scroll movement since the OCR frame whose coordinates the blocks use.
    var overlayEstimate = ScrollEstimate.still
    var placeholderText = "等待屏幕共享"
    private var audioActive = false
    private var audioWarming = false

    /// Activate the playback audio session in the background before the user
    /// starts sharing, so launchStart() does not block the main thread on it.
    func prewarmAudio() {
        guard !audioActive, !audioWarming, voiceCaption == nil else { return }
        audioWarming = true
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            let ok = (try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])) != nil
                && (try? session.setActive(true)) != nil
            await MainActor.run {
                self.audioWarming = false
                if ok && !self.closing { self.audioActive = true }
            }
        }
    }
    private var sessionBegunAt = Date.distantPast
    private(set) var startLatencyMs: Int?
    private var subtitleSignature = ""
    private var cachedSubtitle: CIImage?
    private var voiceCaption: (original: String, translated: String)?
    private var voicePrevious: (original: String, translated: String) = ("", "")
    private var voiceBackgroundOpacity: Double = 0.92
    private var voiceBackgroundBrightness: Double = 0.12
    private var voiceSubtitleColorHex: Int = 0xffffff
    private var voiceShape: VoiceSubtitleShape = .strip
    private var voiceDisplay: VoiceSubtitleDisplay = .bilingual
    private var voiceFont: VoiceSubtitleFont = .medium
    private var voiceWidth: CGFloat = 860
    private var voiceHeight: CGFloat = 180
    private var voiceUsesMicrophone = false
    private var pixelPool: CVPixelBufferPool?
    private var videoFormat: CMVideoFormatDescription?
    private var videoSize: CGSize = .zero
    var renderScope: TranslationScope = .fullScreen
    var renderFixedRegion = CGRect(x: 0.1, y: 0.55, width: 0.8, height: 0.28)
    var renderMode: ScreenDisplayMode = .inPlace
    var selfPiPRegion: CGRect?
    /// Corner locator marks are drawn only until the PiP window has been
    /// found in the captured screen, then hidden; they come back briefly only
    /// when the window seems to have moved.
    var showsLocatorMarks = true
    /// Coarse luminance grid (6×12) of the last frame sent to the PiP.
    private(set) var lastRenderedGrid: [UInt8] = []
    var isActuallyActive: Bool { controller?.isPictureInPictureActive == true }
    var isPossible: Bool { controller?.isPictureInPicturePossible == true }
    var outputFrameSize: CGSize { videoSize }
    var previewSize: CGSize {
        let output = outputSize(for: CGSize(width: 360, height: 780))
        let scale = min(204 / output.width, 346 / output.height)
        return CGSize(width: output.width * scale, height: output.height * scale)
    }

    private func outputSize(for imageSize: CGSize) -> CGSize {
        if voiceCaption != nil {
            return CGSize(width: min(1100, max(420, voiceWidth)),
                          height: min(460, max(100, voiceHeight)))
        }
        if renderMode == .subtitles { return CGSize(width: 780, height: 170) }
        let region = renderScope.viewport(fixedRegion: renderFixedRegion)
        let width = max(1, imageSize.width * region.width)
        let height = max(1, imageSize.height * region.height)
        let scale = 780 / max(width, height)
        return CGSize(width: max(64, round(width * scale)),
                      height: max(64, round(height * scale)))
    }

    func configureIfNeeded() {
        if let controller {
            if controller.contentSource == nil {
                controller.contentSource = AVPictureInPictureController.ContentSource(
                    sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
            }
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            state = "此设备不支持画中画"
            return
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: source)
        controller?.requiresLinearPlayback = true
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStartEnabled
        controller?.delegate = self
        observeAudioInterruptions()
    }

    private var interruptionObserver: NSObjectProtocol?

    /// A full-screen video app (e.g. 抖音) starting its own playback can
    /// interrupt our audio session; the system then treats the PiP as paused
    /// and the app may stop getting time in the background. Re-activate the
    /// session and report "still playing" so live translation keeps going.
    private func observeAudioInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                guard let self, !self.closing, self.isActuallyActive || self.autoStartEnabled else { return }
                qyLog("audio interruption \(type == .began ? "began" : "ended")")
                self.resumeAfterInterruption()
            }
        }
    }

    private func resumeAfterInterruption() {
        let microphone = voiceCaption != nil && voiceUsesMicrophone
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            if microphone {
                try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            } else {
                try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            }
            try? session.setActive(true)
        }
        controller?.invalidatePlaybackState()
    }

    func show(image: UIImage?, blocks: [TextBlock]) {
        if closing { return }
        configureIfNeeded()
        let renderer = view.displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        if controller?.isPictureInPictureActive == true && !renderer.isReadyForMoreMediaData { return }
        let size = outputSize(for: image?.size ?? CGSize(width: 360, height: 780))
        if videoSize != size {
            renderer.flush()
            pixelPool = nil
            videoFormat = nil
            overlaySignature = ""
            subtitleSignature = ""
            cachedSubtitle = nil
            videoSize = size
        }
        if image != nil { placeholderText = "等待屏幕共享" }
        let background = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08))
            .cropped(to: CGRect(origin: .zero, size: size))
        let composed: CIImage
        if let voiceCaption {
            composed = makeVoiceFrame(voiceCaption, size: size)
        } else if renderMode == .subtitles {
            composed = makeSubtitleFrame(image: image, blocks: blocks, size: size) ?? background
        } else if let image, let input = CIImage(image: image) {
            let region = renderScope.viewport(fixedRegion: renderFixedRegion)
            let cropRect = CGRect(x: input.extent.minX + region.minX * input.extent.width,
                                  y: input.extent.minY + (1 - region.maxY) * input.extent.height,
                                  width: region.width * input.extent.width,
                                  height: region.height * input.extent.height)
            let cropped = input.cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            let ratio = min(size.width / cropRect.width, size.height / cropRect.height)
            let fitted = CGSize(width: cropRect.width * ratio, height: cropRect.height * ratio)
            let imageRect = CGRect(x: (size.width - fitted.width) / 2,
                                   y: (size.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height)
            let frame = cropped.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
                .transformed(by: CGAffineTransform(translationX: imageRect.minX, y: imageRect.minY))
            let visibleBlocks = blocks.compactMap { block -> TextBlock? in
                let topLeft = CGRect(x: block.box.minX, y: 1 - block.box.maxY,
                                     width: block.box.width, height: block.box.height)
                let clipped = topLeft.intersection(region)
                guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
                var mapped = block
                mapped.box = CGRect(x: (clipped.minX - region.minX) / region.width,
                                    y: 1 - (clipped.maxY - region.minY) / region.height,
                                    width: clipped.width / region.width,
                                    height: clipped.height / region.height)
                return mapped
            }
            let translatedBlocks = visibleBlocks.filter { !$0.translated.isEmpty && $0.translated != $0.original }
            let key = "\(image.size.width)x\(image.size.height)|\(size)|\(region)|"
                + translatedBlocks.map { "\($0.box):\(String(reflecting: $0.original)):\(String(reflecting: $0.translated))" }.joined(separator: "|")
            let estimate = overlayEstimate
            // Only move translations when the estimate is confident; when unsure,
            // keep the previous behaviour (show them where OCR found them).
            let confidentShift = estimate.shift ?? 0
            let scrolled = confidentShift != 0
            // Background colours are resampled from the current frame, which is only
            // valid while the page sits where the OCR frame saw it.
            let needsBackgroundRefresh = !scrolled && !translatedBlocks.isEmpty
                && Date().timeIntervalSince(overlayDrawnAt) >= 3
            if key != overlaySignature || needsBackgroundRefresh {
                overlaySignature = key
                overlayDrawnAt = Date()
                // Blocks are split by where they sat on the full screen: sticky
                // headers / toolbars stay put while the page body scrolls.
                func screenTop(_ block: TextBlock) -> CGFloat {
                    region.minY + (1 - block.box.midY) * region.height
                }
                let top = visibleBlocks.filter { screenTop($0) < ScrollProfile.bandTop }
                let bottom = visibleBlocks.filter { screenTop($0) > ScrollProfile.bandBottom }
                let body = visibleBlocks.filter {
                    let y = screenTop($0)
                    return y >= ScrollProfile.bandTop && y <= ScrollProfile.bandBottom
                }
                overlay = makeOverlay(blocks: body, imageRect: imageRect,
                                      canvas: size, sourceImage: image, sourceRegion: region)
                topOverlay = makeOverlay(blocks: top, imageRect: imageRect,
                                         canvas: size, sourceImage: image, sourceRegion: region)
                bottomOverlay = makeOverlay(blocks: bottom, imageRect: imageRect,
                                            canvas: size, sourceImage: image, sourceRegion: region)
            }
            var layered = frame
            if let overlay, !scrolled {
                layered = overlay.composited(over: layered)
            } else if let overlay {
                let shift = confidentShift
                // CI y grows upwards: content that moved up moves the overlay up.
                let fullHeight = imageRect.height / max(0.001, region.height)
                let bandMinY = imageRect.minY + (ScrollProfile.bandTop - region.minY) / region.height * imageRect.height
                let bandMaxY = imageRect.minY + (ScrollProfile.bandBottom - region.minY) / region.height * imageRect.height
                let bandRect = CGRect(x: imageRect.minX, y: size.height - bandMaxY,
                                      width: imageRect.width, height: bandMaxY - bandMinY)
                    .intersection(CGRect(x: imageRect.minX, y: size.height - imageRect.maxY,
                                         width: imageRect.width, height: imageRect.height))
                let moved = shift == 0 ? overlay
                    : overlay.transformed(by: CGAffineTransform(translationX: 0, y: shift * fullHeight))
                if !bandRect.isNull { layered = moved.cropped(to: bandRect).composited(over: layered) }
            }
            if let topOverlay { layered = topOverlay.composited(over: layered) }
            if let bottomOverlay { layered = bottomOverlay.composited(over: layered) }
            var translatedFrame = layered.composited(over: background)
            if isActuallyActive, let selfPiPRegion {
                let masked = selfPiPRegion.intersection(region)
                if !masked.isNull, masked.width > 0, masked.height > 0 {
                    let topRect = CGRect(x: imageRect.minX + (masked.minX - region.minX) / region.width * imageRect.width,
                                         y: imageRect.minY + (masked.minY - region.minY) / region.height * imageRect.height,
                                         width: masked.width / region.width * imageRect.width,
                                         height: masked.height / region.height * imageRect.height)
                    let coreRect = CGRect(x: topRect.minX, y: size.height - topRect.maxY,
                                          width: topRect.width, height: topRect.height)
                    let white = CIImage(color: CIColor.white).cropped(to: coreRect)
                    translatedFrame = white.composited(over: translatedFrame)
                }
            }
            composed = translatedFrame
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let waiting = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                (self.placeholderText as NSString).draw(in: CGRect(x: 20, y: (size.height - 60) / 2,
                                                          width: size.width - 40, height: 60),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                                     .foregroundColor: UIColor.white,
                                     .paragraphStyle: paragraph])
            }
            composed = (CIImage(image: waiting) ?? background).composited(over: background)
        }
        if pixelPool == nil {
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                 kCVPixelBufferWidthKey: Int(size.width),
                 kCVPixelBufferHeightKey: Int(size.height),
                 kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelPool)
        }
        var pixel: CVPixelBuffer?
        if let pixelPool { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelPool, &pixel) }
        guard let pixel else { return }
        var framed = composed
        if voiceCaption == nil {
            // Four small dark dots in the corners. ReplayKit captures our own
            // PiP; the dots let every frame find where the window is, so the
            // white cover follows it while it is dragged or resized. They are
            // a very dark green that reads as black but can still be told
            // apart from ordinary black text.
            let (inset, side) = PiPMarkerLayout.metrics(for: size)
            let radius = side / 2
            for x in [inset, size.width - inset - side] {
                for y in [inset, size.height - inset - side] {
                    let center = CIVector(x: x + radius, y: y + radius)
                    if let dot = CIFilter(name: "CIRadialGradient", parameters: [
                        "inputCenter": center,
                        "inputRadius0": max(1, radius - 0.8),
                        "inputRadius1": radius + 0.4,
                        "inputColor0": CIColor(red: 0.04, green: 0.34, blue: 0.16),
                        "inputColor1": CIColor(red: 0.04, green: 0.34, blue: 0.16, alpha: 0)
                    ])?.outputImage?.cropped(to: CGRect(x: x - 1, y: y - 1, width: side + 2, height: side + 2)) {
                        framed = dot.composited(over: framed)
                    }
                }
            }
        }
        context.render(framed, to: pixel)
        if voiceCaption == nil, size.width > 0, size.height > 0 {
            let small = framed.transformed(by: CGAffineTransform(scaleX: 24 / size.width, y: 48 / size.height))
            if let cg = context.createCGImage(small, from: CGRect(x: 0, y: 0, width: 24, height: 48)) {
                lastRenderedGrid = FrameSignature.grid(UIImage(cgImage: cg), columns: 6, rows: 12)
            }
        }
        if videoFormat == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixel, formatDescriptionOut: &videoFormat)
        }
        guard let videoFormat else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                 formatDescription: videoFormat, sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample {
            renderer.enqueue(sample)
        }
    }

    func showVoice(original: String, translated: String,
                   previousOriginal: String, previousTranslated: String,
                   shape: VoiceSubtitleShape,
                   display: VoiceSubtitleDisplay, font: VoiceSubtitleFont,
                   width: CGFloat, height: CGFloat, microphone: Bool,
                   backgroundOpacity: Double, backgroundBrightness: Double, subtitleColorHex: Int) {
        let unchanged = voiceCaption?.original == original && voiceCaption?.translated == translated
            && voicePrevious.original == previousOriginal
            && voicePrevious.translated == previousTranslated
            && voiceBackgroundOpacity == backgroundOpacity
            && voiceBackgroundBrightness == backgroundBrightness
            && voiceSubtitleColorHex == subtitleColorHex
            && voiceShape == shape && voiceDisplay == display && voiceFont == font
            && voiceWidth == width && voiceHeight == height
        let styleChanged = voiceShape != shape || voiceDisplay != display || voiceFont != font
            || voiceWidth != width || voiceHeight != height
        if styleChanged {
            // Discard queued frames with the old shape before applying settings,
            // even if speech is paused or no new translation is arriving.
            view.displayLayer.sampleBufferRenderer.flush()
        }
        voiceCaption = (original, translated)
        voicePrevious = (previousOriginal, previousTranslated)
        voiceBackgroundOpacity = backgroundOpacity
        voiceBackgroundBrightness = backgroundBrightness
        voiceSubtitleColorHex = subtitleColorHex
        voiceShape = shape
        voiceDisplay = display
        voiceFont = font
        voiceWidth = width
        voiceHeight = height
        voiceUsesMicrophone = microphone
        // A recognition revision is not a new subtitle. Keep text at its final
        // coordinates; never move an entire video frame through the PiP window.
        if !unchanged { show(image: nil, blocks: []) }
    }

    func startVoice(autoOnBackground: Bool = false) {
        beginSession()
        configureIfNeeded()
        if !autoOnBackground { ensureStarted() }
    }

    private func makeVoiceFrame(_ caption: (original: String, translated: String),
                                size: CGSize) -> CIImage {
        CIImage(image: VoiceCaptionRenderer.image(original: caption.original,
            translated: caption.translated,
            previousOriginal: voicePrevious.original, previousTranslated: voicePrevious.translated,
            size: size, shape: voiceShape, display: voiceDisplay, font: voiceFont,
            backgroundOpacity: voiceBackgroundOpacity,
            backgroundBrightness: voiceBackgroundBrightness, subtitleColorHex: voiceSubtitleColorHex))
            ?? CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func makeSubtitleFrame(image: UIImage?, blocks: [TextBlock], size: CGSize) -> CIImage? {
        let selected = blocks.filter { !$0.translated.isEmpty && $0.translated != $0.original }
            .max { lhs, rhs in subtitleScore(lhs) < subtitleScore(rhs) }
        let key = "\(selected?.id.uuidString ?? "waiting")|\(selected?.translated ?? "")|\(size.width)x\(size.height)"
        if key == subtitleSignature, let cachedSubtitle { return cachedSubtitle }
        let raw = selected?.translated ?? "等待译文"
        let caption = raw.count > 68 ? String(raw.prefix(68)) + "…" : raw
        let sampled = image.flatMap(PiPBackgroundSampler.init(image:))
            .map { sampler in selected.map { sampler.color(around: $0.box) } ?? .black } ?? .black
        let backgroundColor = sampled.withAlphaComponent(1)
        let foregroundColor: UIColor = backgroundColor.isPiPDark ? .white : .black
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            backgroundColor.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let bounds = CGRect(x: 24, y: 16, width: size.width - 48, height: size.height - 32)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            var fontSize: CGFloat = 42
            while fontSize > 24 {
                let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
                let measured = (caption as NSString).boundingRect(
                    with: bounds.size, options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font, .paragraphStyle: paragraph], context: nil)
                if measured.height <= bounds.height { break }
                fontSize -= 2
            }
            (caption as NSString).draw(in: bounds,
                                       withAttributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                                                        .foregroundColor: foregroundColor,
                                                        .paragraphStyle: paragraph])
        }
        let output = CIImage(image: rendered)
        subtitleSignature = key
        cachedSubtitle = output
        return output
    }

    private func subtitleScore(_ block: TextBlock) -> Double {
        let centerFromTop = Double(1 - block.box.midY)
        let centrality = max(0, 22 - abs(centerFromTop - 0.52) * 55)
        let readableLength = Double(min(block.translated.count, 50)) * 0.6
        return centrality + readableLength + min(15, Double(block.box.width) * 25)
    }

    private func makeOverlay(blocks: [TextBlock], imageRect: CGRect,
                             canvas: CGSize, sourceImage: UIImage, sourceRegion: CGRect) -> CIImage? {
        guard blocks.contains(where: { !$0.translated.isEmpty && $0.translated != $0.original }) else { return nil }
        let sampler = PiPBackgroundSampler(image: sourceImage)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            for block in blocks where !block.translated.isEmpty && block.translated != block.original {
                let rect = CGRect(x: imageRect.minX + block.box.minX * imageRect.width,
                                  y: imageRect.minY + (1 - block.box.maxY) * imageRect.height,
                                  width: block.box.width * imageRect.width,
                                  height: block.box.height * imageRect.height)
                let originalLines = max(1, block.original.split(separator: "\n").count)
                let font = UIFont.systemFont(ofSize: max(8, min(22, rect.height / CGFloat(originalLines) * 0.82)),
                                             weight: .medium)
                let naturalWidth = (block.translated as NSString).size(withAttributes: [.font: font]).width
                let textWidth = min(imageRect.maxX - rect.minX,
                                    max(rect.width + 4, min(naturalWidth + 2, rect.width * 1.2)))
                let textBounds = (block.translated as NSString).boundingRect(
                    with: CGSize(width: max(1, textWidth), height: imageRect.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font], context: nil)
                let backgroundHeight = min(max(rect.height, ceil(textBounds.height) + 2),
                                           imageRect.maxY - rect.minY)
                let padded = CGRect(x: rect.minX - 1, y: rect.minY - 1,
                                    width: textWidth + 2, height: backgroundHeight + 2)
                    .intersection(imageRect)
                let originalBox = CGRect(x: sourceRegion.minX + block.box.minX * sourceRegion.width,
                                         y: (1 - sourceRegion.maxY) + block.box.minY * sourceRegion.height,
                                         width: block.box.width * sourceRegion.width,
                                         height: block.box.height * sourceRegion.height)
                let sampledColor = sampler?.color(around: originalBox) ?? .white
                sampledColor.withAlphaComponent(0.96).setFill()
                UIBezierPath(roundedRect: padded, cornerRadius: 1.5).fill()
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                let textColor: UIColor = sampledColor.isPiPDark ? .white : .black
                (block.translated as NSString).draw(in: padded.insetBy(dx: 1, dy: 1),
                    withAttributes: [.font: font, .foregroundColor: textColor,
                                     .paragraphStyle: paragraph])
            }
        }
        return CIImage(image: image)
    }

    func beginSession(persistentRetries: Bool = false) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        stopTask?.cancel()
        persistentStartRetries = persistentRetries
        closing = false
        autoStartEnabled = true
        startAttempts = 0
        lastStartAttempt = .distantPast
        startPending = false
        subtitleSignature = ""
        cachedSubtitle = nil
        sessionBegunAt = Date()
        startLatencyMs = nil
    }

    func ensureStarted() {
        guard autoStartEnabled, !isActuallyActive, startTask == nil,
              startAttempts < (persistentStartRetries ? 6 : 4) else { return }
        if startPending {
            if Date().timeIntervalSince(startRequestedAt) < 3 { return }
            startPending = false
        }
        guard Date().timeIntervalSince(lastStartAttempt) >= 0.6 else { return }
        launchStart()
    }

    func start() {
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        autoStartEnabled = true
        startAttempts = 0
        lastStartAttempt = .distantPast
        startPending = false
        startTask?.cancel()
        startTask = nil
        ensureStarted()
    }

    private func launchStart() {
        configureIfNeeded()
        do {
            if voiceCaption != nil && voiceUsesMicrophone {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                    options: [.mixWithOthers, .defaultToSpeaker])
            } else {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback,
                    options: [.mixWithOthers])
            }
            // Activation is a slow synchronous call; prewarmAudio() normally did it
            // off the main thread already, so PiP start is not blocked here.
            if !audioActive { try AVAudioSession.sharedInstance().setActive(true) }
            audioActive = true
        } catch {
            state = "音频会话配置失败：\(error.localizedDescription)"
            return
        }
        startAttempts += 1
        lastStartAttempt = Date()
        qyLog("pip launchStart attempt \(startAttempts) possible=\(controller?.isPictureInPicturePossible == true) appState=\(UIApplication.shared.applicationState.rawValue)")
        startTask = Task { @MainActor in
            defer { startTask = nil }
            for _ in 0..<300 {
                if Task.isCancelled || !autoStartEnabled { return }
                // Starting while the system broadcast sheet still covers the app
                // fails and costs a retry; wait for the app to become active.
                if let controller, controller.isPictureInPicturePossible,
                   UIApplication.shared.applicationState == .active {
                    qyLog("pip possible+active after \(Int(Date().timeIntervalSince(sessionBegunAt) * 1000))ms, starting")
                    if !controller.isPictureInPictureActive {
                        state = "正在开启画中画"
                        startPending = true
                        startRequestedAt = Date()
                        controller.startPictureInPicture()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            state = "系统尚未允许画中画启动"
        }
    }
    func stop() {
        autoStartEnabled = false
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        startPending = false
        closing = true
        voiceCaption = nil
        startTask?.cancel()
        stopTask?.cancel()
        if isActuallyActive {
            awaitingStopCallback = true
            state = "正在关闭画中画"
            controller?.stopPictureInPicture()
            // A Control Center broadcast stop can suspend the host immediately.
            // Detach the source and audio session before yielding to any Task;
            // the delayed retry below may never get CPU time in the background.
            controller?.contentSource = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            audioActive = false
            stopTask = Task { @MainActor in
                for attempt in 0..<20 {
                    if Task.isCancelled { return }
                    if !isActuallyActive {
                        view.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
                        state = "画中画已关闭"
                        return
                    }
                    controller?.stopPictureInPicture()
                    try? await Task.sleep(for: .milliseconds(200))
                }
                state = isActuallyActive ? "系统尚未关闭画中画" : "画中画已关闭"
            }
        } else {
            state = "画中画已关闭"
            controller?.contentSource = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            audioActive = false
            view.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.startPending = false
            if !self.autoStartEnabled || self.closing {
                pictureInPictureController.stopPictureInPicture()
                self.state = "正在关闭画中画"
            } else {
                self.state = "画中画正在显示"
                if self.startLatencyMs == nil, self.sessionBegunAt != .distantPast {
                    self.startLatencyMs = Int(Date().timeIntervalSince(self.sessionBegunAt) * 1000)
                    qyLog("pip did start, \(self.startLatencyMs ?? -1)ms after session begin")
                }
            }
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                               failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            qyLog("pip failed to start: \(error.localizedDescription)")
            self.startPending = false; self.state = "画中画失败：\(error.localizedDescription)"
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            let stoppedByApp = self.awaitingStopCallback
            self.awaitingStopCallback = false
            if stoppedByApp && !self.closing && self.autoStartEnabled {
                // A previous session's stop callback arrived after a new start.
                self.startPending = false
                self.state = "正在准备画中画"
                self.ensureStarted()
                return
            }
            if !self.closing && !stoppedByApp { self.autoStartEnabled = false }
            self.closing = false
            self.startPending = false
            self.state = "画中画已关闭"
            self.view.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        // Live translation has no pause: when the system (or another app's
        // video) asks the PiP to pause, keep it in the playing state.
        Task { @MainActor in
            if !playing {
                qyLog("pip asked to pause; staying live")
                self.resumeAfterInterruption()
            }
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion: @escaping () -> Void) { completion() }
}

/// Live picture of what the PiP shows. Collapsed it stays in the window at
/// 1 pt (AVKit needs the source layer); expanded it fills the card width at
/// the video's own aspect ratio instead of the small fixed preview size.
struct PiPLivePreview: View {
    let pip: SubtitlePiP
    let expanded: Bool
    var cornerRadius: CGFloat = 22
    var body: some View {
        let size = pip.previewSize
        if expanded {
            PiPSourceView(controller: pip)
                .aspectRatio(size.width / max(1, size.height), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 560)
                .background(.black, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .frame(maxWidth: .infinity)
        } else {
            PiPSourceView(controller: pip)
                .frame(width: size.width, height: size.height)
                .frame(width: 1, height: 1)
                .clipped()
                .opacity(0.02)
                .accessibilityHidden(true)
        }
    }
}

struct PiPSourceView: UIViewRepresentable {
    let controller: SubtitlePiP
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.addSubview(controller.view)
        controller.view.frame = host.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.configureIfNeeded()
        return host
    }
    func updateUIView(_ view: UIView, context: Context) {
        // The same video view may move between the collapsed and the
        // expanded preview; take it back if another host released it.
        if controller.view.superview == nil { view.addSubview(controller.view) }
        if controller.view.superview === view { controller.view.frame = view.bounds }
    }
}

/// Size and position of the four corner marks drawn into the PiP video.
private enum PiPMarkerLayout {
    static func metrics(for size: CGSize) -> (inset: CGFloat, side: CGFloat) {
        let side = max(10, (min(size.width, size.height) * 0.05).rounded())
        return (max(12, (side * 0.9).rounded()), side)
    }
}

private enum PiPRegionDetector {
    private struct Mark {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var count: Int
        var centerX: Double { Double(minX + maxX) / 2 }
        var centerY: Double { Double(minY + maxY) / 2 }
    }

    /// Four small fiducials are placed at known offsets in the video image.
    /// Their rectangle identifies the largest (outer) PiP, even if smaller
    /// recursive copies are present. All coordinates here are top-left based.
    static func detect(in image: UIImage, videoSize: CGSize) -> CGRect? {
        guard let cgImage = image.cgImage, videoSize.width > 70, videoSize.height > 70 else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 100, height > 100 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        func isMarker(_ index: Int) -> Bool {
            let offset = index * 4
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            // Also matches the marks while the PiP controls dim the video.
            return green >= 34 && green - red >= 16 && green - blue >= 10
                && red < 200 && blue < 200
        }
        var visited = [Bool](repeating: false, count: width * height)
        var marks: [Mark] = []
        for y in 0..<height {
            for x in 0..<width {
                let start = y * width + x
                guard !visited[start], isMarker(start) else { continue }
                visited[start] = true
                var stack = [start]
                var mark = Mark(minX: x, maxX: x, minY: y, maxY: y, count: 0)
                while let pixel = stack.popLast() {
                    let px = pixel % width, py = pixel / width
                    mark.count += 1
                    mark.minX = min(mark.minX, px); mark.maxX = max(mark.maxX, px)
                    mark.minY = min(mark.minY, py); mark.maxY = max(mark.maxY, py)
                    for ny in max(0, py - 1)...min(height - 1, py + 1) {
                        for nx in max(0, px - 1)...min(width - 1, px + 1) {
                            let neighbor = ny * width + nx
                            if !visited[neighbor] && isMarker(neighbor) {
                                visited[neighbor] = true
                                stack.append(neighbor)
                            }
                        }
                    }
                }
                let markWidth = mark.maxX - mark.minX + 1
                let markHeight = mark.maxY - mark.minY + 1
                if mark.count >= 4 && mark.count <= 3600,
                   (2...60).contains(markWidth), (2...60).contains(markHeight),
                   Double(max(markWidth, markHeight)) <= Double(min(markWidth, markHeight)) * 2.2 + 1,
                   Double(mark.count) / Double(markWidth * markHeight) >= 0.35 {
                    marks.append(mark)
                }
            }
        }
        guard marks.count >= 4 else { return nil }
        let layout = PiPMarkerLayout.metrics(for: videoSize)
        let sourceInset = Double(layout.inset + layout.side / 2)
        let sourceDX = Double(videoSize.width) - sourceInset * 2
        let sourceDY = Double(videoSize.height) - sourceInset * 2
        guard sourceDX > 30, sourceDY > 30 else { return nil }
        let expectedRatio = sourceDX / sourceDY
        var best: CGRect?
        var bestArea = 0.0
        for topLeft in marks {
            for topRight in marks {
                let dx = topRight.centerX - topLeft.centerX
                guard dx >= 35, abs(topRight.centerY - topLeft.centerY) <= 7 else { continue }
                for bottomLeft in marks {
                    let dy = bottomLeft.centerY - topLeft.centerY
                    guard dy >= 35, abs(bottomLeft.centerX - topLeft.centerX) <= 7 else { continue }
                    let ratio = dx / dy
                    guard ratio >= expectedRatio * 0.72 && ratio <= expectedRatio * 1.28 else { continue }
                    let scaleX = dx / sourceDX, scaleY = dy / sourceDY
                    guard scaleX / scaleY >= 0.72 && scaleX / scaleY <= 1.28 else { continue }
                    guard let bottomRight = marks.first(where: {
                        abs($0.centerX - topRight.centerX) <= 7 &&
                        abs($0.centerY - bottomLeft.centerY) <= 7
                    }) else { continue }
                    let minCount = min(topLeft.count, topRight.count, bottomLeft.count, bottomRight.count)
                    let maxCount = max(topLeft.count, topRight.count, bottomLeft.count, bottomRight.count)
                    guard maxCount <= minCount * 5 else { continue }
                    let area = dx * dy
                    guard area > bestArea else { continue }
                    bestArea = area
                    // A small margin covers the PiP's rounded corners and shadow.
                    let pad = 4 + Double(width) * 0.012
                    let x = max(0, topLeft.centerX - sourceInset * scaleX - pad)
                    let y = max(0, topLeft.centerY - sourceInset * scaleY - pad)
                    let maxX = min(Double(width), topLeft.centerX - sourceInset * scaleX + Double(videoSize.width) * scaleX + pad)
                    let maxY = min(Double(height), topLeft.centerY - sourceInset * scaleY + Double(videoSize.height) * scaleY + pad)
                    best = CGRect(x: x / Double(width), y: y / Double(height),
                                  width: (maxX - x) / Double(width),
                                  height: (maxY - y) / Double(height))
                }
            }
        }
        return best
    }
}

private struct PiPBackgroundSampler {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        var buffer = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: imageWidth, height: imageHeight,
                                          bitsPerComponent: 8, bytesPerRow: imageWidth * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard drew else { return nil }
        width = imageWidth
        height = imageHeight
        bytes = buffer
    }

    func color(around box: CGRect) -> UIColor {
        let margin = 3.0 / Double(height)
        let points: [(Double, Double)] = [
            (box.minX, min(0.999, box.maxY + margin)),
            (box.maxX, min(0.999, box.maxY + margin)),
            (box.minX, max(0, box.minY - margin)),
            (box.maxX, max(0, box.minY - margin))
        ]
        var channels = [[Int](), [Int](), [Int]()]
        for (x, y) in points {
            let px = min(width - 1, max(0, Int(x * Double(width))))
            let py = min(height - 1, max(0, Int((1 - y) * Double(height))))
            let offset = (py * width + px) * 4
            for channel in 0..<3 { channels[channel].append(Int(bytes[offset + channel])) }
        }
        let median = channels.map { values -> CGFloat in
            let sorted = values.sorted()
            return CGFloat(sorted[sorted.count / 2]) / 255
        }
        return UIColor(red: median[0], green: median[1], blue: median[2], alpha: 1)
    }
}

private extension UIColor {
    var isPiPDark: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: nil)
        return red * 0.2126 + green * 0.7152 + blue * 0.0722 < 0.40
    }
}
