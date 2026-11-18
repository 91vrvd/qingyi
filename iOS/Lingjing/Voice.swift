import SwiftUI
import AVFoundation
import Speech
import ReplayKit

enum VoiceAudioSource: String, CaseIterable, Identifiable, Codable {
    case phone = "手机声音"
    case microphone = "身边讲话"
    var id: String { rawValue }
    var detail: String {
        self == .phone ? "翻译系统屏幕共享中允许采集的手机声音" : "翻译 iPhone 麦克风听到的讲话"
    }
}

enum VoiceSubtitleShape: String, CaseIterable, Identifiable, Codable {
    case strip = "紧凑"
    case horizontal = "标准"
    case card = "卡片"
    case adaptive = "迷你条"
    var id: String { rawValue }
    var defaultSize: CGSize {
        switch self {
        case .strip: CGSize(width: 960, height: 210)
        case .horizontal: CGSize(width: 920, height: 370)
        case .card: CGSize(width: 780, height: 450)
        case .adaptive: CGSize(width: 1000, height: 120)
        }
    }
}

enum VoiceSubtitleDisplay: String, CaseIterable, Identifiable, Codable {
    case translated = "只看译文"
    case bilingual = "双语"
    case original = "只看原文"
    var id: String { rawValue }
}

enum VoiceSubtitleFont: String, CaseIterable, Identifiable, Codable {
    case small = "小"
    case medium = "中"
    case large = "大"
    var id: String { rawValue }
}

struct SubtitleLine: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var original: String
    var translated: String
}

struct VoiceSession: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var duration: TimeInterval
    var source: String
    var target: String? = nil
    var audioSource: VoiceAudioSource
    var lines: [SubtitleLine]
    var notes: String? = nil
    var exportText: String {
        let transcript = lines.map { line in
            let seconds = max(0, Int(line.date.timeIntervalSince(date)))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
                + "  " + line.original + "\n" + line.translated
        }.joined(separator: "\n\n")
        let memo = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return memo.isEmpty ? transcript : transcript + "\n\n备注\n" + memo
    }
}

/// Microphone level for the live view's small meter. Kept out of VoiceModel so
/// level changes (many per second) redraw only the meter, not the transcript.
@MainActor final class VoiceLevel: ObservableObject {
    @Published private(set) var bucket = 0
    func update(peak: Float) {
        let value = peak < 0.012 ? 0 : peak < 0.04 ? 1 : peak < 0.1 ? 2 : peak < 0.2 ? 3 : 4
        if value != bucket { bucket = value }
    }
}

@MainActor final class VoiceModel: ObservableObject {
    let level = VoiceLevel()
    @Published var source: AppLanguage = .english
    @Published var target: AppLanguage = .simplifiedChinese
    @Published var audioSource: VoiceAudioSource = .microphone {
        didSet { UserDefaults.standard.set(audioSource.rawValue, forKey: "voiceAudioSource") }
    }
    @Published var shape: VoiceSubtitleShape = .strip {
        didSet { UserDefaults.standard.set(shape.rawValue, forKey: "voiceShape"); updatePiP(force: true) }
    }
    @Published var display: VoiceSubtitleDisplay = .bilingual {
        didSet { UserDefaults.standard.set(display.rawValue, forKey: "voiceDisplay"); updatePiP(force: true) }
    }
    @Published var fontChoice: VoiceSubtitleFont = .medium {
        didSet { UserDefaults.standard.set(fontChoice.rawValue, forKey: "voiceFont"); updatePiP(force: true) }
    }
    @Published var backgroundOpacity: Double = 0.92 {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: "voiceBackgroundOpacity"); updatePiP(force: true) }
    }
    @Published var backgroundBrightness: Double = 0.12 {
        didSet { UserDefaults.standard.set(backgroundBrightness, forKey: "voiceBackgroundBrightness"); updatePiP(force: true) }
    }
    @Published var subtitleColorHex: Int = 0xffffff {
        didSet { UserDefaults.standard.set(subtitleColorHex, forKey: "voiceSubtitleColor"); updatePiP(force: true) }
    }
    @Published var customWidth: Double = 0 {
        didSet { UserDefaults.standard.set(customWidth, forKey: "voiceWidth"); updatePiP(force: true) }
    }
    @Published var customHeight: Double = 0 {
        didSet { UserDefaults.standard.set(customHeight, forKey: "voiceHeight"); updatePiP(force: true) }
    }
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var current = ""
    @Published var currentTranslation = ""
    @Published var message = "准备就绪"
    @Published var lines: [SubtitleLine] = []
    @Published var conversationLines: [SubtitleLine] = []
    @Published var sessions: [VoiceSession] = []
    @Published var completedSession: VoiceSession?
    @Published var autoSave: Bool = UserDefaults.standard.object(forKey: "autoSaveSubtitles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSave, forKey: "autoSaveSubtitles") }
    }
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var partialTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var transcriptToken = 0
    private var partialGeneration = 0
    private var translatedOriginal = ""
    private let translator = LocalTranslator()
    let pip = SubtitlePiP()
    private var startedAt = Date()
    private var lastAudioAt = Date.distantPast
    private var observedBroadcast = false
    private var phoneFinishing = false
    private var phoneArmedAt: Date?
    private var starting = false
    private var useOnDeviceRecognition = true
    private var recognitionGeneration = 0
    private var lastCommitted = ""
    private var historyIDs: [Int: UUID] = [:]
    private var conversationIDs: [Int: [UUID]] = [:]
    private var conversationSnapshots: [Int: String] = [:]
    private var activeConversationID = UUID()
    private var lastConversationSave = Date.distantPast
    private var conversationTranslatedSource: [UUID: String] = [:]
    private var conversationTask: Task<Void, Never>?
    private var conversationToken = 0
    private var shownCaptionLines: [SubtitleLine] = []
    private var shownCaptionIDs: [String: UUID] = [:]
    private struct Caption {
        var key: String
        var original: String
        var translated: String
        var final = false
    }
    private var translatedCueKey = ""
    @Published private var visibleCaption = Caption(key: "", original: "", translated: "")
    @Published private var previousCaption = Caption(key: "", original: "", translated: "")
    private var pendingCaption: Caption?
    private var captionTimer: Task<Void, Never>?
    private var lastCaptionChange = Date.distantPast
    private var captionBeganAt = Date.distantPast
    private var holdCaptionUntil = Date.distantPast
    private var groupFolder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup)
    }

    init() {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "voiceAudioSource").flatMap(VoiceAudioSource.init(rawValue:)) {
            audioSource = value
        }
        if let value = defaults.string(forKey: "voiceShape").flatMap(VoiceSubtitleShape.init(rawValue:)) {
            shape = value
        }
        if let value = defaults.string(forKey: "voiceDisplay").flatMap(VoiceSubtitleDisplay.init(rawValue:)) {
            display = value
        }
        if let value = defaults.string(forKey: "voiceFont").flatMap(VoiceSubtitleFont.init(rawValue:)) {
            fontChoice = value
        }
        if let old = defaults.string(forKey: "voiceShape"),
           VoiceSubtitleShape(rawValue: old) == nil {
            shape = ["宽条": .strip, "横条": .horizontal, "自适应": .adaptive][old] ?? .strip
        }
        if defaults.object(forKey: "voiceBackgroundOpacity") != nil {
            backgroundOpacity = defaults.double(forKey: "voiceBackgroundOpacity")
        }
        if defaults.object(forKey: "voiceBackgroundBrightness") != nil {
            backgroundBrightness = defaults.double(forKey: "voiceBackgroundBrightness")
        }
        if defaults.object(forKey: "voiceSubtitleColor") != nil { subtitleColorHex = defaults.integer(forKey: "voiceSubtitleColor") }
        customWidth = defaults.double(forKey: "voiceWidth")
        customHeight = defaults.double(forKey: "voiceHeight")
    }

    var subtitleSize: CGSize {
        let base = shape.defaultSize
        let height = customHeight > 0 ? customHeight : base.height
        return CGSize(width: min(1100, max(420, customWidth > 0 ? customWidth : base.width)),
                      height: min(460, max(100, height)))
    }

    var captionOriginal: String {
        if !translatedOriginal.isEmpty && !currentTranslation.isEmpty { return translatedOriginal }
        return Self.subtitleCue(current).text
    }

    var captionTranslation: String { currentTranslation }

    // Stable pages, not a moving suffix: adding a word must not discard the
    // first word of the same cue. Commas do not force a subtitle change.
    private static func subtitleCue(_ text: String) -> (key: String, text: String) {
        let clauses = text.split(whereSeparator: { ".!?。！？;；\n".contains($0) })
        guard let last = clauses.last else { return ("0:0", "") }
        let clause = last.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = clause.split(whereSeparator: \.isWhitespace)
        if words.count > 1 {
            let page = (words.count - 1) / 14
            return ("\(clauses.count - 1):\(page)", words.dropFirst(page * 14).joined(separator: " "))
        }
        // CJK languages (Japanese, Chinese, etc.) have no whitespace between words;
        // paginate long clauses by character count so PiP subtitles stay readable.
        if clause.count > 28 {
            let pageSize = 24
            let page = (clause.count - 1) / pageSize
            let start = clause.index(clause.startIndex, offsetBy: page * pageSize)
            return ("\(clauses.count - 1):\(page)", String(clause[start...]))
        }
        return ("\(clauses.count - 1):0", clause)
    }

    var stylePreviewPreviousOriginal: String {
        isRunning ? previousCaption.original : ""
    }
    var stylePreviewPreviousTranslation: String {
        isRunning ? previousCaption.translated : ""
    }
    var stylePreviewOriginal: String {
        isRunning ? visibleCaption.original : "Markets are born in despair and grow amid skepticism."
    }
    var stylePreviewTranslation: String {
        isRunning ? visibleCaption.translated : "行情总在绝望中诞生，在半信半疑中成长。"
    }

    func selectShape(_ value: VoiceSubtitleShape) {
        customWidth = 0
        customHeight = 0
        shape = value
    }

    func armPhoneBroadcast() {
        guard !isRunning, audioSource == .phone, let folder = groupFolder else { return }
        phoneArmedAt = Date()
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("voice.stop"))
        try? "phone".write(to: folder.appendingPathComponent("voice.mode"), atomically: true, encoding: .utf8)
    }

    /// The system 屏幕共享 sheet was opened for 手机声音; shown as 等待系统确认.
    @Published private(set) var awaitingSystem = false
    @Published private(set) var startError: String?
    private var awaitingSince = Date.distantPast

    func clearStartError() {
        startError = nil
    }

    func beginAwaitingSystem() {
        guard !isRunning, audioSource == .phone else { return }
        startError = nil
        armPhoneBroadcast()
        awaitingSystem = true
        awaitingSince = Date()
        message = "等待系统确认"
    }

    func cancelAwaitingSystem() {
        awaitingSystem = false
        if !isRunning { message = "准备就绪" }
    }

    func disarmPhoneBroadcast() {
        guard !isRunning, !starting else { return }
        phoneArmedAt = nil
        if let folder = groupFolder { try? FileManager.default.removeItem(at: folder.appendingPathComponent("voice.mode")) }
    }

    private func failStart(_ reason: String, stopBroadcast: Bool = false) {
        awaitingSystem = false
        phoneArmedAt = nil
        startError = reason
        message = reason
        if stopBroadcast, audioSource == .phone, let groupFolder {
            try? FileManager.default.removeItem(at: groupFolder.appendingPathComponent("voice.mode"))
            try? "stop".write(to: groupFolder.appendingPathComponent("voice.stop"),
                              atomically: true, encoding: .utf8)
        }
    }

    /// Check translation readiness and speech recognition availability before
    /// presenting the system broadcast sheet so non-English pairs do not hang
    /// at "等待系统确认" when a pack or permission is missing.
    func preflightPhoneStart() async -> (error: String?, needsLanguagePack: Bool) {
        startError = nil
        let sourceCode = source.code ?? "en"
        if source != target {
            let fastReady = MLKitEngine.shared.canServe(source: sourceCode, target: target.code ?? "zh-Hans")
            if !fastReady {
                let state = await translator.status(for: sourceCode, target: target)
                if state != .installed {
                    let msg = state == .unsupported
                        ? "这组翻译语言暂不支持"
                        : "请先下载 \(source.rawValue) → \(target.rawValue) 翻译语言包或离线模型"
                    failStart(msg)
                    return (msg, state != .unsupported)
                }
            } else {
                MLKitEngine.shared.prepare(source: sourceCode, target: target.code ?? "zh-Hans")
            }
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            let msg = "请在系统设置中允许语音识别"
            failStart(msg)
            return (msg, false)
        }
        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: source.speechLocale))
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            let msg = "\(source.rawValue)语音识别当前不可用（请检查网络或系统听写设置）"
            failStart(msg)
            return (msg, false)
        }
        return (nil, false)
    }

    func start() {
        guard !isRunning, !starting else { return }
        starting = true
        startError = nil
        Task {
            defer { starting = false }
            let sourceCode = source.code ?? "en"
            // With the fast offline engine selected and its models downloaded,
            // Apple's language pack is not required to start.
            let fastReady = MLKitEngine.shared.canServe(source: sourceCode,
                                                        target: target.code ?? "zh-Hans")
            if source != target && !fastReady {
                let state = await translator.status(for: sourceCode, target: target)
                guard state == .installed else {
                    failStart(state == .unsupported ? "这组翻译语言暂不支持" : "请先点语言包状态，下载 \(source.rawValue) → \(target.rawValue)",
                              stopBroadcast: audioSource == .phone)
                    return
                }
            } else if source != target {
                MLKitEngine.shared.prepare(source: sourceCode, target: target.code ?? "zh-Hans")
            }
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else {
                failStart("请在设置中允许语音识别", stopBroadcast: audioSource == .phone)
                return
            }
            if audioSource == .microphone {
                let mic = await AVAudioApplication.requestRecordPermission()
                guard mic else {
                    failStart("请在设置中允许麦克风")
                    return
                }
            }
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: source.speechLocale))
            guard let recognizer, recognizer.isAvailable else {
                failStart("当前语种（\(source.rawValue)）的语音识别暂不可用", stopBroadcast: audioSource == .phone)
                return
            }
            // Prefer on-device recognition when available, but allow online
            // recognition fallback so non-English languages (e.g. Japanese,
            // Chinese) without downloaded dictation packs still work and open PiP.
            useOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            do {
                if audioSource == .microphone {
                    try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                        options: [.mixWithOthers, .defaultToSpeaker])
                    try AVAudioSession.sharedInstance().setActive(true)
                } else {
                    guard let groupFolder else {
                        failStart("共享容器不可用", stopBroadcast: true)
                        return
                    }
                    try? FileManager.default.removeItem(
                        at: groupFolder.appendingPathComponent("voice.stop"))
                    try "phone".write(to: groupFolder.appendingPathComponent("voice.mode"),
                                      atomically: true, encoding: .utf8)
                }
                awaitingSystem = false
                startedAt = Date()
                lastAudioAt = .distantPast
                observedBroadcast = false
                phoneFinishing = false
                lastCommitted = ""
                completedSession = nil
                lines = []
                conversationLines = []
                conversationIDs = [:]
                conversationSnapshots = [:]
                conversationTranslatedSource = [:]
                activeConversationID = UUID()
                lastConversationSave = .distantPast
                historyIDs = [:]
                shownCaptionLines = []
                shownCaptionIDs = [:]
                current = ""
                currentTranslation = ""
                translatedOriginal = ""
                visibleCaption = Caption(key: "", original: "", translated: "")
                previousCaption = Caption(key: "", original: "", translated: "")
                pendingCaption = nil
                captionTimer?.cancel()
                captionTimer = nil
                lastCaptionChange = .distantPast
                captionBeganAt = .distantPast
                translatedCueKey = ""
                        holdCaptionUntil = .distantPast
                isRunning = true
                isPaused = false
                if audioSource == .microphone {
                    startRecognitionTask()
                    engine.inputNode.installTap(onBus: 0, bufferSize: 1024,
                        format: engine.inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                        self?.request?.append(buffer)
                        if let samples = buffer.floatChannelData?[0] {
                            let count = Int(buffer.frameLength)
                            var peak: Float = 0
                            for index in stride(from: 0, to: count, by: 32) {
                                peak = max(peak, abs(samples[index]))
                            }
                            let loud = peak > 0.012
                            Task { @MainActor [weak self] in
                                self?.level.update(peak: peak)
                                if loud { self?.lastAudioAt = Date() }
                            }
                        }
                    }
                    tapInstalled = true
                    engine.prepare()
                    try engine.start()
                    message = useOnDeviceRecognition ? "正在收听麦克风（本机识别）" : "正在收听麦克风（在线识别）"
                } else {
                    message = "等待系统广播开始；请在系统面板确认"
                }
                pip.beginSession(persistentRetries: audioSource == .phone)
                updatePiP(force: true)
                pip.startVoice(autoOnBackground: audioSource == .microphone)
            } catch {
                failStart("启动失败：\(error.localizedDescription)", stopBroadcast: audioSource == .phone)
                stop()
            }
        }
    }

    private func startRecognitionTask() {
        cancelTranscriptTranslation()
        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask?.cancel()
        request?.endAudio()
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = useOnDeviceRecognition
        request = next
        recognitionTask = recognizer?.recognitionTask(with: next) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isPaused,
                      self.recognitionGeneration == generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.recordRecognition(text, generation: generation)
                    self.recordConversation(result.bestTranscription, generation: generation)
                    if result.isFinal {
                        self.current = text
                        self.updatePiP(final: true)
                        if self.phoneFinishing { return }
                        self.current = ""
                        self.startRecognitionTask()
                        // Persist the finished sentence without interrupting the
                        // next utterance's live translation loop.
                        Task { await self.commit(text, generation: generation) }
                    } else if text != self.current {
                        if self.current.isEmpty {
                            self.currentTranslation = ""
                            self.translatedOriginal = ""
                        }
                        self.current = text
                        self.updatePiP()
                        self.schedulePartial(text)
                    }
                } else if let error {
                    // If on-device recognition fails (common when a non-English
                    // dictation model is incomplete), fall back to online
                    // recognition instead of tearing down PiP immediately.
                    if self.useOnDeviceRecognition {
                        self.useOnDeviceRecognition = false
                        self.message = self.audioSource == .phone ? "已切换在线识别，正在收听手机声音" : "已切换在线识别，正在收听麦克风"
                        self.startRecognitionTask()
                        return
                    }
                    self.message = "语音识别中断：\(error.localizedDescription)"
                    self.stop()
                }
            }
        }
    }

    func elapsedLabel(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func tick() {
        if awaitingSystem && (isRunning || starting || Date().timeIntervalSince(awaitingSince) > 90) {
            awaitingSystem = false
        }
        if !isRunning, !starting, audioSource == .phone,
           let armed = phoneArmedAt, let folder = groupFolder {
            let stateURL = folder.appendingPathComponent("capture.state")
            let attrs = try? FileManager.default.attributesOfItem(atPath: stateURL.path)
            let modified = attrs?[.modificationDate] as? Date
            let state = (try? String(contentsOf: stateURL, encoding: .utf8)) ?? ""
            if state == "running", let modified,
               (modified >= armed.addingTimeInterval(-1.5) || (awaitingSystem && Date().timeIntervalSince(modified) < 4.0)) {
                phoneArmedAt = nil
                start()
            }
        }
        pollPhoneAudio()
        guard isRunning, !isPaused, currentTranslation.isEmpty,
              Date().timeIntervalSince(startedAt) > 2,
              Date().timeIntervalSince(lastAudioAt) > 2,
              visibleCaption.key != "silence" else { return }
        presentCaption(Caption(key: "silence", original: "没听到声音", translated: ""))
    }

    func pollPhoneAudio() {
        guard isRunning, audioSource == .phone, !isPaused, let groupFolder else { return }
        let state = (try? String(contentsOf: groupFolder.appendingPathComponent("capture.state"),
                                 encoding: .utf8)) ?? ""
        if !pip.isActuallyActive { pip.ensureStarted() }
        guard state == "running" || (state == "stopped" && observedBroadcast) else { return }
        if !observedBroadcast { startRecognitionTask() }
        observedBroadcast = true
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: groupFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("voice-audio-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in (state == "stopped" ? files : Array(files.prefix(12))) {
            if let data = try? Data(contentsOf: file),
               let buffer = VoiceAudioPacket.decode(data) {
                request?.append(buffer)
                lastAudioAt = Date()
                message = useOnDeviceRecognition ? "正在收听手机声音（本机识别）" : "正在收听手机声音（在线识别）"
            }
            try? FileManager.default.removeItem(at: file)
        }
        if state == "stopped", !phoneFinishing {
            phoneFinishing = true
            request?.endAudio()
            message = "正在保存最后的字幕…"
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, self.isRunning, self.audioSource == .phone, self.phoneFinishing else { return }
                self.stop()
                self.message = "屏幕共享已停止"
            }
            return
        }
        if lastAudioAt == .distantPast, Date().timeIntervalSince(startedAt) > 8 {
            message = "没有听到手机声音；静音或受保护内容无法识别"
        }
    }

    func pause() {
        guard isRunning else { return }
        cancelTranscriptTranslation()
        partialTask?.cancel()
        partialTask = nil
        captionTimer?.cancel()
        captionTimer = nil
        pendingCaption = nil
        if audioSource == .microphone { engine.pause() }
        isPaused = true
        message = "已暂停"
        updatePiP(force: true)
    }

    func resume() {
        guard isRunning, isPaused else { return }
        do {
            if audioSource == .microphone { try engine.start() }
            isPaused = false
            startRecognitionTask()
            message = "正在识别"
            updatePiP(force: true)
        }
        catch { message = "恢复失败：\(error.localizedDescription)" }
    }

    func stop() {
        guard isRunning || tapInstalled else { return }
        cancelTranscriptTranslation()
        conversationToken += 1
        conversationTask?.cancel()
        conversationTask = nil
        let pendingHistoryID = historyIDs[recognitionGeneration]
        let pendingOriginal = current
        let pendingWasFullyTranslated = pendingOriginal.trimmingCharacters(in: .punctuationCharacters) == translatedOriginal.trimmingCharacters(in: .punctuationCharacters) && !currentTranslation.isEmpty
        let historyStartedAt = startedAt
        let historySource = source
        let historyTarget = target
        partialTask?.cancel()
        partialTask = nil
        captionTimer?.cancel()
        captionTimer = nil
        pendingCaption = nil
        visibleCaption = Caption(key: "", original: "", translated: "")
        previousCaption = Caption(key: "", original: "", translated: "")
        partialGeneration += 1
        recognitionGeneration += 1
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil; recognitionTask = nil
        if audioSource == .phone, let groupFolder {
            try? FileManager.default.removeItem(at: groupFolder.appendingPathComponent("voice.mode"))
            try? "stop".write(to: groupFolder.appendingPathComponent("voice.stop"),
                              atomically: true, encoding: .utf8)
            try? "stopped".write(to: groupFolder.appendingPathComponent("capture.state"),
                                 atomically: true, encoding: .utf8)
        }
        pip.stop()
        phoneFinishing = false
        phoneArmedAt = nil
        isRunning = false; isPaused = false
        try? AVAudioSession.sharedInstance().setActive(false)
        current = ""
        currentTranslation = ""
        translatedOriginal = ""
        let sessionLines = conversationLines.isEmpty ? (shownCaptionLines.isEmpty ? lines : shownCaptionLines) : conversationLines
        if !sessionLines.isEmpty {
            completedSession = VoiceSession(id: activeConversationID, date: startedAt,
                duration: Date().timeIntervalSince(startedAt), source: source.rawValue,
                target: target.rawValue, audioSource: audioSource, lines: sessionLines)
        }
        if autoSave, let completedSession {
            if let index = sessions.firstIndex(where: { $0.id == completedSession.id }) {
                sessions[index] = completedSession
            } else {
                sessions.insert(completedSession, at: 0)
            }
            sessions = Array(sessions.prefix(200))
            save()
        }
        if !conversationLines.isEmpty, let session = completedSession {
            let pending = session.lines.filter { conversationTranslatedSource[$0.id] != $0.original }
            Task { [weak self] in
                guard let self else { return }
                for line in pending {
                    do {
                        let value = try await self.translateFullRecord(line.original, source: historySource, target: historyTarget)
                        if let sessionIndex = self.sessions.firstIndex(where: { $0.id == session.id }),
                           let index = self.sessions[sessionIndex].lines.firstIndex(where: { $0.id == line.id && $0.original == line.original }) {
                            self.sessions[sessionIndex].lines[index].translated = value
                            if self.completedSession?.id == session.id { self.completedSession = self.sessions[sessionIndex] }
                            self.save()
                        } else if self.completedSession?.id == session.id,
                                  let index = self.completedSession?.lines.firstIndex(where: { $0.id == line.id && $0.original == line.original }) {
                            self.completedSession?.lines[index].translated = value
                        }
                    } catch { self.message = "字幕原文已保留，部分译文未完成：\(error.localizedDescription)" }
                }
            }
        }
        if audioSource == .phone, conversationLines.isEmpty, let pendingHistoryID, !pendingOriginal.isEmpty,
           shownCaptionLines.isEmpty, lines.contains(where: { $0.id == pendingHistoryID }), !pendingWasFullyTranslated {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let value = try await self.translateFullRecord(pendingOriginal, source: historySource, target: historyTarget)
                    if let sessionIndex = self.sessions.firstIndex(where: { $0.date == historyStartedAt }),
                       let index = self.sessions[sessionIndex].lines.firstIndex(where: { $0.id == pendingHistoryID && $0.original == pendingOriginal }) {
                        self.sessions[sessionIndex].lines[index].translated = value
                        if self.completedSession?.id == self.sessions[sessionIndex].id { self.completedSession = self.sessions[sessionIndex] }
                        self.save()
                    } else if self.completedSession?.date == historyStartedAt,
                              let index = self.completedSession?.lines.firstIndex(where: { $0.id == pendingHistoryID && $0.original == pendingOriginal }) {
                        self.completedSession?.lines[index].translated = value
                    }
                } catch { self.message = "字幕原文已保留，完整译文未完成：\(error.localizedDescription)" }
            }
        }
        if message.hasPrefix("正在") { message = "已停止" }
    }

    private func schedulePartial(_ original: String) {
        guard !original.isEmpty, partialTask == nil else { return }
        let expected = partialGeneration
        partialTask = Task { @MainActor in
            var previous = ""
            while isRunning, !isPaused, !Task.isCancelled,
                  expected == partialGeneration {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled || expected != partialGeneration { break }
                let cue = Self.subtitleCue(current)
                let snapshot = cue.text
                let generation = recognitionGeneration
                if snapshot.isEmpty { break }
                let identity = "\(generation):\(cue.key):\(snapshot)"
                if identity == previous { break }
                if identity != previous {
                    previous = identity
                    do {
                        let value = try await translator.translate(snapshot, source: source, target: target)
                        if !Task.isCancelled, expected == partialGeneration,
                           generation == recognitionGeneration {
                            // Speech can add words during Translation's await.
                            // This completed caption is still useful, and the
                            // next iteration immediately translates the latest tail.
                            translatedOriginal = snapshot
                            translatedCueKey = "\(generation):\(cue.key)"
                            currentTranslation = value
                            updatePiP()
                        }
                    } catch {
                        if expected == partialGeneration { message = error.localizedDescription }
                    }
                }
            }
            if expected == partialGeneration { partialTask = nil }
        }
    }

    private func recordRecognition(_ text: String, generation: Int) {
        guard !text.isEmpty else { return }
        if let id = historyIDs[generation], let index = lines.firstIndex(where: { $0.id == id }) {
            if lines[index].original != text {
                lines[index].original = text
            }
        } else {
            let line = SubtitleLine(original: text, translated: "")
            historyIDs[generation] = line.id
            lines.append(line)
        }
    }

    // Keep conversation entries separate from the rolling PiP subtitle.
    private func recordConversation(_ transcription: SFTranscription, generation: Int) {
        let full = transcription.formattedString as NSString
        var groups: [String] = []
        var start: Int?
        var end = 0
        var previousEnd: TimeInterval?
        for segment in transcription.segments {
            let range = segment.substringRange
            guard range.location != NSNotFound, NSMaxRange(range) <= full.length else { continue }
            let gap = previousEnd.map { segment.timestamp - $0 } ?? 0
            if let first = start, (gap > 0.65 || end - first >= 100) {
                let value = full.substring(with: NSRange(location: first, length: end - first)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { groups.append(value) }
                start = nil
            }
            if start == nil { start = range.location }
            end = NSMaxRange(range)
            previousEnd = segment.timestamp + segment.duration
            let word = full.substring(with: range)
            if let last = word.last, ".!?。！？；;".contains(last), let first = start {
                let value = full.substring(with: NSRange(location: first, length: end - first)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { groups.append(value) }
                start = nil
            }
        }
        if let first = start, end >= first {
            let value = full.substring(with: NSRange(location: first, length: end - first)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { groups.append(value) }
        }
        if groups.isEmpty, !transcription.formattedString.isEmpty { groups = [transcription.formattedString] }
        guard !groups.isEmpty else { return }
        let newSnapshot = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldSnapshot = conversationSnapshots[generation] ?? ""
        let oldComparable = oldSnapshot.lowercased().filter { $0.isLetter || $0.isNumber }
        let newComparable = newSnapshot.lowercased().filter { $0.isLetter || $0.isNumber }
        let common = zip(oldComparable, newComparable).prefix { $0 == $1 }.count
        // A new utterance does not continue the old text's beginning. The old
        // rule needed 20+ characters, so short Chinese sentences (often under
        // 20 characters) were overwritten by the next sentence instead of being
        // kept as their own line.
        // A revision keeps most of the old beginning; a new utterance shares
        // at most a word or two (Chinese sentences often begin with the same
        // character, so a longer new sentence used to overwrite the old line).
        let reset = oldComparable.count >= 2
            && common < max(1, min(oldComparable.count, newComparable.count) / 2)
        if reset {
            // Speech can start a new rolling hypothesis without issuing a final
            // result. Keep the old lines and allocate IDs for the new text.
            conversationIDs[generation] = []
        }
        conversationSnapshots[generation] = newSnapshot
        var ids = conversationIDs[generation] ?? []
        while ids.count < groups.count {
            let line = SubtitleLine(original: "", translated: "")
            ids.append(line.id)
            conversationLines.append(line)
        }
        if ids.count > groups.count {
            // The recognizer merged groups in its newer hypothesis. Previously
            // the IDs were dropped, so the next update appended a second copy of
            // the same sentence. Update the lines in place and drop the extras.
            let extra = Set(ids[groups.count...])
            conversationLines.removeAll { extra.contains($0.id) }
            for id in extra { conversationTranslatedSource.removeValue(forKey: id) }
            ids = Array(ids.prefix(groups.count))
        }
        conversationIDs[generation] = ids
        for (offset, text) in groups.enumerated() {
            guard let index = conversationLines.firstIndex(where: { $0.id == ids[offset] }) else { continue }
            if conversationLines[index].original != text {
                // Keep the previous translation on screen until the new one
                // arrives. Clearing it here made every recognizer revision blank
                // the line and re-flow the transcript (visible jumping).
                conversationLines[index].original = text
            }
        }
        scheduleConversationTranslation()
        checkpointConversation()
    }

    private func checkpointConversation(force: Bool = false) {
        guard autoSave, isRunning, !conversationLines.isEmpty,
              force || Date().timeIntervalSince(lastConversationSave) >= 2 else { return }
        lastConversationSave = Date()
        let session = VoiceSession(id: activeConversationID, date: startedAt,
            duration: Date().timeIntervalSince(startedAt), source: source.rawValue,
            target: target.rawValue, audioSource: audioSource, lines: conversationLines)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.insert(session, at: 0); sessions = Array(sessions.prefix(200)) }
        save()
    }

    private func scheduleConversationTranslation() {
        guard conversationTask == nil, isRunning else { return }
        let token = conversationToken
        conversationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Short debounce only: the fast offline engine translates a line in
            // tens of milliseconds, so waiting 450 ms made captions lag speech.
            try? await Task.sleep(for: .milliseconds(120))
            while self.isRunning, !Task.isCancelled, self.conversationToken == token {
                guard let line = self.conversationLines.first(where: {
                    !$0.original.isEmpty && self.conversationTranslatedSource[$0.id] != $0.original
                }) else { break }
                do {
                    let value = try await self.translateFullRecord(line.original, source: self.source, target: self.target)
                    guard !Task.isCancelled, self.conversationToken == token else { break }
                    if let index = self.conversationLines.firstIndex(where: { $0.id == line.id }) {
                        // Accept the result even if speech revised the line in the
                        // meantime; the loop picks the newer text up right away.
                        if self.conversationLines[index].translated != value {
                            self.conversationLines[index].translated = value
                        }
                        self.conversationTranslatedSource[line.id] = line.original
                        self.checkpointConversation()
                    }
                } catch {
                    if !Task.isCancelled { self.message = "记录译文暂不可用：\(error.localizedDescription)" }
                    break
                }
            }
            if self.conversationToken == token { self.conversationTask = nil }
        }
    }

    private func cancelTranscriptTranslation() {
        transcriptToken += 1
        transcriptTask?.cancel()
        transcriptTask = nil
    }

    private func updateHistoryTranslation(_ translation: String, generation: Int, original: String) {
        guard let id = historyIDs[generation],
              let index = lines.firstIndex(where: { $0.id == id }),
              (lines[index].original == original || lines[index].original.hasPrefix(original)) else { return }
        lines[index].translated = translation
    }

    private func translateFullRecord(_ text: String, source: AppLanguage, target: AppLanguage,
                                     onProgress: ((String) -> Void)? = nil) async throws -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        var pieces: [String] = []
        if words.count > 1 {
            var buffer = ""
            for word in words {
                let next = buffer.isEmpty ? String(word) : buffer + " " + word
                if next.count > 140 && !buffer.isEmpty { pieces.append(buffer); buffer = String(word) } else { buffer = next }
                if buffer.count >= 35, let last = buffer.last, ".!?。！？；;".contains(last) {
                    pieces.append(buffer)
                    buffer = ""
                }
            }
            if !buffer.isEmpty { pieces.append(buffer) }
        } else {
            var remaining = text[...]
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: min(100, remaining.count))
                pieces.append(String(remaining[..<end])); remaining = remaining[end...]
            }
        }
        var translated: [String] = []
        for piece in pieces {
            try Task.checkCancellation()
            translated.append(try await translator.translate(piece, source: source, target: target))
            onProgress?(translated.joined(separator: " "))
        }
        return translated.joined(separator: " ")
    }

    private func commit(_ original: String, generation: Int) async {
        let sessionStartedAt = startedAt
        let lineID = historyIDs[generation]
        guard !original.isEmpty, original != lastCommitted else { return }
        lastCommitted = original
        do {
            let settled = original.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation: String
            if !currentTranslation.isEmpty,
               settled.trimmingCharacters(in: .punctuationCharacters)
                == translatedOriginal.trimmingCharacters(in: .punctuationCharacters) {
                translation = currentTranslation
            } else {
                translation = try await translateFullRecord(original, source: source, target: target)
            }
            if isRunning, startedAt == sessionStartedAt {
                updateHistoryTranslation(translation, generation: generation, original: original)
            } else if let lineID, let sessionIndex = sessions.firstIndex(where: { $0.date == sessionStartedAt }),
                      let index = sessions[sessionIndex].lines.firstIndex(where: { $0.id == lineID && $0.original == original }) {
                sessions[sessionIndex].lines[index].translated = translation
                save()
            }
            guard isRunning, startedAt == sessionStartedAt else { return }
            // History may contain a whole paragraph. Do not replace the live
            // cue with that paragraph, or let an old final overwrite new speech.
            let cue = Self.subtitleCue(original)
            guard current.isEmpty, recognitionGeneration == generation + 1 else { return }
            let cueTranslation = cue.text == original ? translation
                : try await translator.translate(cue.text, source: source, target: target)
            guard isRunning, !isPaused, startedAt == sessionStartedAt,
                  current.isEmpty, recognitionGeneration == generation + 1 else { return }
            translatedOriginal = cue.text
            translatedCueKey = "\(generation):\(cue.key)"
            currentTranslation = cueTranslation
            updatePiP(final: true)
        } catch { message = error.localizedDescription }
    }

    /// While idle, show a sample caption in the subtitle window preview instead
    /// of an empty black bar; it also previews style changes immediately.
    func renderIdlePreview() {
        guard !isRunning, !starting else { return }
        let size = subtitleSize
        pip.showVoice(original: stylePreviewOriginal, translated: stylePreviewTranslation,
                      previousOriginal: "", previousTranslated: "",
                      shape: shape, display: display, font: fontChoice, width: size.width,
                      height: size.height, microphone: audioSource == .microphone,
                      backgroundOpacity: backgroundOpacity,
                      backgroundBrightness: backgroundBrightness, subtitleColorHex: subtitleColorHex)
    }

    func updatePiP(force: Bool = false, final: Bool = false) {
        guard isRunning else { if force { renderIdlePreview() }; return }
        if isPaused {
            presentCaption(Caption(key: "paused", original: "已暂停", translated: "已暂停"))
            return
        }
        if force, !visibleCaption.original.isEmpty, visibleCaption.key != "paused" {
            renderCaption()
            return
        }
        let candidate = Caption(key: translatedCueKey,
            original: captionOriginal.isEmpty ? "等待讲话" : captionOriginal,
            translated: captionTranslation, final: final)
        if candidate.translated.isEmpty {
            // Keep the previous translated cue while the next one is being
            // recognized, instead of flashing a one-word fragment over it.
            if visibleCaption.translated.isEmpty, visibleCaption.key != "silence" {
                if Date().timeIntervalSince(lastCaptionChange) >= 0.5 || force {
                    presentCaption(candidate)
                }
            }
            return
        }
        if candidate.key == visibleCaption.key,
           candidate.original == visibleCaption.original,
           candidate.translated == visibleCaption.translated {
            if final && !visibleCaption.final {
                visibleCaption.final = true
                holdCaptionUntil = Date().addingTimeInterval(1.0)
            }
            return
        }
        pendingCaption = candidate
        scheduleCaption()
    }

    private func scheduleCaption() {
        guard let candidate = pendingCaption else { return }
        captionTimer?.cancel()
        let now = Date()
        let newCue = candidate.key != visibleCaption.key
        var nextAt = lastCaptionChange.addingTimeInterval(0.65)
        if visibleCaption.translated.isEmpty || visibleCaption.key == "paused" {
            nextAt = now
        } else if newCue {
            // Leave each cue readable, but keep only the newest pending result
            // so rapid speech cannot build an ever-growing subtitle backlog.
            nextAt = max(nextAt, max(holdCaptionUntil, captionBeganAt.addingTimeInterval(1.6)))
            let words = candidate.original.split(whereSeparator: \.isWhitespace).count
            let short = words < 3 && candidate.translated.count < 6
            if short && !candidate.final { nextAt = max(nextAt, now.addingTimeInterval(0.65)) }
        }
        if now >= nextAt {
            pendingCaption = nil
            presentCaption(candidate)
        } else {
            captionTimer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, nextAt.timeIntervalSinceNow)))
                guard !Task.isCancelled, isRunning, !isPaused,
                      let latest = pendingCaption else { return }
                captionTimer = nil
                pendingCaption = nil
                presentCaption(latest)
            }
        }
    }

    private func presentCaption(_ caption: Caption) {
        if !caption.translated.isEmpty, !caption.original.isEmpty,
           caption.key != "paused", caption.key != "silence", !caption.key.isEmpty {
            if let id = shownCaptionIDs[caption.key], let index = shownCaptionLines.firstIndex(where: { $0.id == id }) {
                shownCaptionLines[index].original = caption.original
                shownCaptionLines[index].translated = caption.translated
            } else {
                let line = SubtitleLine(original: caption.original, translated: caption.translated)
                shownCaptionIDs[caption.key] = line.id
                shownCaptionLines.append(line)
            }
        }
        let newCue = caption.key != visibleCaption.key || visibleCaption.translated.isEmpty
        if newCue {
            if !visibleCaption.translated.isEmpty, visibleCaption.key != "paused" {
                previousCaption = visibleCaption
            }
            captionBeganAt = Date()
        }
        if caption.final && (!visibleCaption.final || newCue) {
            holdCaptionUntil = Date().addingTimeInterval(1.0)
        }
        visibleCaption = caption
        lastCaptionChange = Date()
        renderCaption()
    }

    private func renderCaption() {
        let size = subtitleSize
        pip.showVoice(original: visibleCaption.original, translated: visibleCaption.translated,
                      previousOriginal: previousCaption.original,
                      previousTranslated: previousCaption.translated,
                      shape: shape, display: display, font: fontChoice, width: size.width,
                      height: size.height, microphone: audioSource == .microphone,
                      backgroundOpacity: backgroundOpacity,
                      backgroundBrightness: backgroundBrightness, subtitleColorHex: subtitleColorHex)
    }

    func retranslateRecord(_ id: UUID) async throws {
        guard let session = sessions.first(where: { $0.id == id }) ?? (completedSession?.id == id ? completedSession : nil),
              let from = AppLanguage(rawValue: session.source),
              let to = AppLanguage(rawValue: session.target ?? "简体中文") else { return }
        for line in session.lines where !line.original.isEmpty {
            let result = try await translateFullRecord(line.original, source: from, target: to)
            if let sessionIndex = sessions.firstIndex(where: { $0.id == id }),
               let lineIndex = sessions[sessionIndex].lines.firstIndex(where: { $0.id == line.id && $0.original == line.original }) {
                sessions[sessionIndex].lines[lineIndex].translated = result
                if completedSession?.id == id { completedSession = sessions[sessionIndex] }
                save()
            } else if completedSession?.id == id,
                      let lineIndex = completedSession?.lines.firstIndex(where: { $0.id == line.id && $0.original == line.original }) {
                completedSession?.lines[lineIndex].translated = result
            }
        }
    }

    func updateRecordNotes(_ id: UUID, notes: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].notes = notes
            if completedSession?.id == id { completedSession = sessions[index] }
            save()
        } else if completedSession?.id == id { completedSession?.notes = notes }
    }

    func clear() { sessions = []; save() }
    func delete(_ id: UUID) { sessions.removeAll { $0.id == id }; save() }

    private var recordURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("voice-sessions.json")
    }
    func load() {
        if let recordURL, let data = try? Data(contentsOf: recordURL),
           let saved = try? JSONDecoder().decode([VoiceSession].self, from: data) {
            sessions = saved
            return
        }
        // Preserve records written by the first microphone prototype.
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? Data(contentsOf: folder.appendingPathComponent("subtitles.json")),
           let old = try? JSONDecoder().decode([SubtitleLine].self, from: data),
           let first = old.first, let last = old.last {
            sessions = [VoiceSession(date: first.date,
                duration: max(0, last.date.timeIntervalSince(first.date)),
                source: source.rawValue, audioSource: .microphone, lines: old)]
            save()
        }
    }
    private func save() {
        guard let recordURL, let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: recordURL, options: .atomic)
    }
}

private enum VoiceAudioPacket {
    static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count >= 14, Array(data.prefix(4)) == [81, 89, 65, 49] else { return nil }
        let bytes = [UInt8](data)
        let rate = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        let channels = Int(bytes[8])
        let bigEndian = bytes[9] == 1
        let frames = Int(bytes[10]) | Int(bytes[11]) << 8 | Int(bytes[12]) << 16 | Int(bytes[13]) << 24
        guard rate >= 8000, rate <= 96000, (1...2).contains(channels),
              frames > 0, frames < 96000, bytes.count >= 14 + frames * channels * 2,
              !bytes[14..<(14 + frames * channels * 2)].allSatisfy({ $0 == 0 }),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(rate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                let index = 14 + (frame * channels + channel) * 2
                let value = bigEndian
                    ? UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
                    : UInt16(bytes[index + 1]) << 8 | UInt16(bytes[index])
                sum += Float(Int16(bitPattern: value)) / 32768
            }
            output[frame] = sum / Float(channels)
        }
        return buffer
    }
}

/// Prominent voice status (replaces the small caption): 准备收音 →
/// 等待系统确认 → 正在开启画中画 → 正在听.
struct VoiceStatusHeader: View {
    @ObservedObject var model: VoiceModel
    @ObservedObject var pip: SubtitlePiP

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10).shadow(color: color.opacity(0.6), radius: 5)
                Text(title).font(.system(size: 26, weight: .bold))
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.2), value: title)
    }

    /// Title / detail / starting flag, shared with the 雾面 layout.
    @MainActor static func info(model: VoiceModel, pip: SubtitlePiP) -> (title: String, detail: String, starting: Bool) {
        let starting = model.isRunning && model.audioSource == .phone && !pip.isActuallyActive
        let title: String
        if model.isRunning { title = starting ? "正在开启画中画" : (model.isPaused ? "已暂停" : "正在听") }
        else if model.awaitingSystem { title = "等待系统确认" }
        else if model.startError != nil { title = "无法开启字幕" }
        else { title = "准备收音" }
        let detail: String
        if model.isRunning {
            detail = starting ? "请留在本页，小窗弹出后再回到视频。"
                : (model.audioSource == .phone ? "回到视频，字幕会出现在画中画小窗里。" : "对着手机讲话，字幕会实时出现。")
        } else if model.awaitingSystem {
            detail = "请在系统弹出的面板里点「开始直播」。"
        } else if let error = model.startError {
            detail = error
        } else {
            detail = model.audioSource == .phone
                ? "点「开启字幕」，在系统面板里开始直播，就能识别手机里播放的声音。"
                : "点「开启字幕」，识别身边的讲话并实时翻译。"
        }
        return (title, detail, starting)
    }

    private var phoneStarting: Bool {
        model.isRunning && model.audioSource == .phone && !pip.isActuallyActive
    }
    private var busy: Bool { model.awaitingSystem || phoneStarting }
    private var title: String {
        if model.isRunning { return phoneStarting ? "正在开启画中画" : (model.isPaused ? "已暂停" : "正在听") }
        if model.awaitingSystem { return "等待系统确认" }
        if model.startError != nil { return "无法开启字幕" }
        return "准备收音"
    }
    private var detail: String {
        if model.isRunning {
            if phoneStarting { return "请留在本页，小窗弹出后再回到视频。" }
            return model.audioSource == .phone ? "回到视频，字幕会出现在画中画小窗里。" : "对着手机讲话，字幕会实时出现。"
        }
        if model.awaitingSystem { return "请在系统弹出的面板里点「开始直播」。" }
        if let error = model.startError { return error }
        return model.audioSource == .phone
            ? "点「开启字幕」，在系统面板里开始直播，就能识别手机里播放的声音。"
            : "点「开启字幕」，识别身边的讲话并实时翻译。"
    }
    private var color: Color {
        if model.isRunning && !phoneStarting { return model.isPaused ? .orange : .green }
        if !model.isRunning && !model.awaitingSystem && model.startError != nil { return .red }
        if busy { return .orange }
        return .gray
    }
}

/// While the subtitles are in the PiP window, iOS paints its own
/// "此视频正以画中画播放" placeholder into the source view; in the short
/// subtitle strip its icon and text overlap. Cover it with a one-line note.
struct PiPActiveCover: View {
    @ObservedObject var pip: SubtitlePiP
    var body: some View {
        if pip.isActuallyActive {
            ZStack {
                Color.black
                HStack(spacing: 8) {
                    Image(systemName: "pip").font(.system(size: 14, weight: .medium))
                    Text("字幕正在小窗中显示").font(.system(size: 14, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Voice level shown as a pie stat on the 雾面 card.
struct MistVoiceLevelStat: View {
    @ObservedObject var level: VoiceLevel
    var body: some View {
        MistStat(fraction: Double(level.bucket) / 4, text: ["静", "弱", "中", "强", "响"][min(4, max(0, level.bucket))], dim: true)
    }
}

/// Arc whose ticks follow the live voice level.
struct MistVoiceArc: View {
    @ObservedObject var level: VoiceLevel
    let labels: [String]
    let progress: Double
    let active: Bool
    var body: some View {
        MistArcGauge(labels: labels, progress: progress, active: active,
                     level: 0.15 + Double(level.bucket) / 4 * 0.85)
            .equatable()
    }
}

struct VoiceHome: View {
    @StateObject private var installedLanguages = InstalledLanguageOptions()
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @ObservedObject var model: VoiceModel
    @State private var showAudioSource = false
    @State private var showStyle = false
    @State private var showHistory = false
    @State private var showHelp = false
    @State private var showLive = false
    @State private var showVoiceGuide = false
    @State private var continueAfterVoiceGuide = false
    @State private var voicePickerTrigger = 0
    @AppStorage("voiceStartGuideHidden") private var voiceGuideHidden = false

    var body: some View {
        Group {
        if visualTheme == 5 { mistLayout } else if visualTheme == 4 { nativeThemeLayout } else if visualTheme == 3 { themeFourLayout } else if visualTheme == 2 { themeThreeLayout } else if visualTheme == 1 { warmLayout } else {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Circle().fill(model.isRunning ? .green : .gray)
                            .frame(width: 10, height: 10)
                        Text(model.isRunning ? "字幕正在运行" : "先选择讲话的语言")
                            .font(.system(size: 26, weight: .light, design: .rounded))
                        Spacer()
                    }
                    Text(model.message).font(.subheadline).foregroundStyle(.white.opacity(0.88))
                    PiPSourceView(controller: model.pip).overlay { PiPActiveCover(pip: model.pip) }
                        .aspectRatio(model.subtitleSize.width / model.subtitleSize.height, contentMode: .fit)
                        .frame(maxWidth: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: .infinity)
                }
                .padding(18)
                .clearGlass(28)
                TranslationReadinessView(source: model.source, target: model.target, speech: true)
                VStack(spacing: 0) {
                    HStack {
                        Text("原文语言")
                        Spacer()
                        Picker("原文语言", selection: $model.source) {
                            ForEach(installedLanguages.sourceOptions(current: model.source, auto: false)) {
                                Text(installedLanguages.sourceLabel($0)).tag($0).disabled(!installedLanguages.sources.contains($0))
                            }
                        }.labelsHidden().pickerStyle(.menu).disabled(model.isRunning)
                    }.padding()
                    Divider()
                    HStack {
                        Text("译成")
                        Spacer()
                        Picker("目标语言", selection: $model.target) {
                            ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) }
                        }.labelsHidden().pickerStyle(.menu).disabled(model.isRunning)
                    }.padding()
                    Divider()
                    Button { showAudioSource = true } label: {
                        HStack {
                            Text("音频来源").foregroundStyle(.white)
                            Spacer()
                            Text(model.audioSource.rawValue).foregroundStyle(.white.opacity(0.88))
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.88))
                        }.padding()
                    }.disabled(model.isRunning)
                    Divider()
                    Button { showStyle = true } label: {
                        HStack {
                            Text("字幕样式").foregroundStyle(.white)
                            Spacer()
                            Text("\(model.shape.rawValue) · \(model.fontChoice.rawValue) · \(model.display.rawValue)")
                                .foregroundStyle(.white.opacity(0.88))
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.88))
                        }.padding()
                    }
                }.clearGlass(20)
                if !model.isRunning && model.audioSource == .phone {
                    ZStack {
                        Text("开启字幕").font(.headline).frame(maxWidth: .infinity).padding()
                            .foregroundStyle(.white)
                            .clearGlass(30)
                        VoiceBroadcastStartPicker { model.beginAwaitingSystem() }
                    }.frame(height: 54)
                } else {
                    Button(model.isRunning ? "关闭字幕" : "开启字幕") {
                        model.isRunning ? model.stop() : model.start()
                    }
                    .font(.headline).frame(maxWidth: .infinity).padding()
                    .foregroundStyle(.white)
                    .background(model.isRunning ? Color.red.opacity(0.35) : Color.clear, in: Capsule()).clearGlass(30)
                }
                if model.isRunning {
                    HStack {
                        Button(model.isPaused ? "恢复" : "暂停") {
                            model.isPaused ? model.resume() : model.pause()
                        }
                        if model.audioSource == .phone {
                            Spacer()
                            Text("系统广播").font(.footnote)
                            BroadcastPicker().frame(width: 48, height: 48)
                        }
                    }.padding(.horizontal, 10)
                }
                if model.isRunning {
                    Button { showLive = true } label: { Label("查看实时记录", systemImage: "text.bubble").frame(maxWidth: .infinity, alignment: .leading).padding().clearGlass(18) }
                }
                if !model.current.isEmpty || !model.lines.isEmpty {
                    Button { showStyle = true } label: { VoiceCaptionPreview(model: model) }.buttonStyle(.plain).accessibilityLabel("调整字幕样式")
                }
                Button { showHistory = true } label: {
                    Label("字幕记录", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding().clearGlass(18)
                }
                Button { showHelp = true } label: {
                    Label("使用说明", systemImage: "questionmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding().clearGlass(18)
                }
                Text("语音识别与翻译优先在本机处理。手机声音需开启系统屏幕共享；受保护内容可能没有声音。画中画大小由 iOS 控制，字幕比例可在样式中调整。")
                    .font(.footnote).foregroundStyle(.white.opacity(0.88))
            }.padding().foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        }
        } }
        .task(id: "\(model.source.rawValue)|\(model.target.rawValue)") {
            model.clearStartError()
            if model.source != model.target {
                MLKitEngine.shared.prepare(source: model.source.code ?? "en", target: model.target.code ?? "zh-Hans")
            }
            await installedLanguages.refresh(source: model.source, target: model.target, speech: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QingyiLanguagePacksChanged"))) { _ in Task { await installedLanguages.refresh(source: model.source, target: model.target, speech: true) } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await installedLanguages.refresh(source: model.source, target: model.target, speech: true) } }
        .onAppear {
            model.armPhoneBroadcast()
            // Deferred so the tab switch animation is not held up.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                model.renderIdlePreview()
            }
        }
        .onDisappear { model.disarmPhoneBroadcast() }
        .onChange(of: model.audioSource) { _, source in
            if source == .phone { model.armPhoneBroadcast() } else { model.disarmPhoneBroadcast() }
        }
        .onChange(of: model.isRunning) { _, running in
            if running && model.audioSource == .microphone { showLive = true }
            if !running && model.audioSource == .phone { model.armPhoneBroadcast() }
        }
        .fullScreenCover(isPresented: $showLive) { VoiceLiveView(model: model) }
        .sheet(isPresented: $showAudioSource) {
            NavigationStack {
                List(VoiceAudioSource.allCases) { source in
                    Button {
                        model.audioSource = source
                        showAudioSource = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(source.rawValue).font(.headline)
                                Text(source.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.audioSource == source {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                .background(GlassWallpaper())
                .navigationTitle("音频来源")
                .mistSheet()
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showAudioSource = false }
                } }
            }.presentationDetents([.medium])
        }
        .sheet(isPresented: $showStyle) { VoiceStyleView(model: model).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showHistory) { VoiceHistoryView(model: model) }
        .sheet(isPresented: $showHelp) { VoiceHelpView() }
        .background(alignment: .topLeading) {
            HiddenBroadcastPicker(trigger: voicePickerTrigger).frame(width: 4, height: 4)
        }
        .sheet(isPresented: $showVoiceGuide, onDismiss: {
            if continueAfterVoiceGuide { continueAfterVoiceGuide = false; openVoicePicker() }
        }) {
            BroadcastGuideSheet(
                title: "三步开启视频字幕",
                subtitle: "青译翻译会听手机里正在播放的声音，把双语字幕放进小窗。",
                steps: [(icon: "pip.remove", text: "如果视频 App 会自动开画中画，先在它的设置里关掉，免得把字幕窗顶掉"),
                        (icon: "record.circle", text: "在系统面板里点「开始直播」——面板写的是屏幕共享，但只会用到声音"),
                        (icon: "play.rectangle", text: "回到视频继续播放，字幕会在小窗里实时出现")],
                note: "声音只在这台手机上识别和翻译，不会上传。",
                onContinue: { continueAfterVoiceGuide = true; showVoiceGuide = false },
                onNeverShow: { voiceGuideHidden = true; continueAfterVoiceGuide = true; showVoiceGuide = false })
        }
    }

    // MARK: 雾面

    private var mistLayout: some View {
        let info = VoiceStatusHeader.info(model: model, pip: model.pip)
        let phone = model.audioSource == .phone
        let labels = phone ? ["准备", "系统确认", "开启小窗", "收听中"] : ["准备", "开始", "收听中"]
        let progress: Double = {
            if model.isRunning && !info.starting { return phone ? 0.875 : 5.0 / 6 }
            if model.isRunning { return 0.625 }
            if model.awaitingSystem { return 0.375 }
            return phone ? 0.125 : 1.0 / 6
        }()
        let words = model.lines.reduce(0) { $0 + $1.original.count }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MistTopBar(title: "语音翻译") {
                    MistCircleButton(systemImage: "questionmark", label: "使用说明") { showHelp = true }
                } right: {
                    MistCircleButton(systemImage: "slider.horizontal.3", label: "字幕样式") { showStyle = true }
                }
                MistSegment(caption: "听谁说话",
                            options: [(value: VoiceAudioSource.microphone, icon: "person.wave.2", title: "身边讲话"),
                                      (value: VoiceAudioSource.phone, icon: "iphone.radiowaves.left.and.right", title: "手机里的声音")],
                            selection: model.audioSource, disabled: model.isRunning) { model.audioSource = $0 }

                VStack(alignment: .leading, spacing: 12) {
                    if model.isRunning {
                        MistCardHeader(title: "双语字幕", actionTitle: "实时记录") { showLive = true }
                    } else {
                        MistCardHeader(title: "双语字幕", actionTitle: "历史记录") { showHistory = true }
                    }
                    HStack(alignment: .center) {
                        if model.isRunning {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                MistBigValue(value: model.elapsedLabel(at: context.date), suffix: "")
                            }
                        } else {
                            MistBigValue(value: model.source.mistCode, suffix: "→ \(model.target.rawValue)")
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .leading, spacing: 10) {
                            MistStat(fraction: min(1, Double(model.lines.count) / 20), text: "\(model.lines.count) 句")
                            MistStat(fraction: min(1, Double(words) / 500), text: "\(words) 字", dim: true)
                        }
                    }
                    MistVoiceArc(level: model.level, labels: labels, progress: progress,
                                 active: model.isRunning && !model.isPaused)
                        .padding(.horizontal, -22)
                    MistInsight(title: info.title, detail: info.detail)
                    // Subtitle window preview (also the PiP source).
                    Button { showStyle = true } label: {
                        PiPSourceView(controller: model.pip).overlay { PiPActiveCover(pip: model.pip) }
                            .aspectRatio(model.subtitleSize.width / model.subtitleSize.height, contentMode: .fit)
                            .frame(maxHeight: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("字幕小窗预览，轻点调整样式")
                    if !model.isRunning && phone {
                        if model.awaitingSystem {
                            HStack(spacing: 10) {
                                MistPrimaryButton(title: "取消", systemImage: "xmark", quiet: true) { model.cancelAwaitingSystem() }
                                    .frame(width: 120)
                                MistPrimaryButton(title: "重新打开面板", systemImage: "record.circle") { openVoicePicker() }
                            }
                        } else {
                            MistPrimaryButton(title: "开启字幕", systemImage: "waveform") {
                                if voiceGuideHidden { openVoicePicker() } else { showVoiceGuide = true }
                            }
                        }
                    } else if model.isRunning {
                        HStack(spacing: 10) {
                            MistPrimaryButton(title: model.isPaused ? "继续" : "暂停",
                                              systemImage: model.isPaused ? "play.fill" : "pause.fill", quiet: true) {
                                model.isPaused ? model.resume() : model.pause()
                            }
                            .frame(width: 120)
                            MistPrimaryButton(title: "结束字幕", systemImage: "stop.fill") { model.stop() }
                        }
                    } else {
                        MistPrimaryButton(title: "开启字幕", systemImage: "waveform") { model.start() }
                    }
                    if !model.isRunning {
                        HStack(spacing: 10) {
                            Menu {
                                Picker("原文", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: false)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled(!installedLanguages.sources.contains($0)) } }
                            } label: { MistMenuLabel(title: "讲话语言", value: model.source.rawValue) }
                            Menu {
                                Picker("译成", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }
                            } label: { MistMenuLabel(title: "译成", value: model.target.rawValue) }
                        }
                        TranslationReadinessView(source: model.source, target: model.target)
                            .foregroundStyle(Mist.inkSoft).lineLimit(1)
                    }
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
                Text("语音翻译").font(.largeTitle.bold()).padding(.top, 12)
                VStack(alignment: .leading, spacing: 10) { VoiceStatusHeader(model: model, pip: model.pip); PiPSourceView(controller: model.pip).overlay { PiPActiveCover(pip: model.pip) }.aspectRatio(model.subtitleSize.width / model.subtitleSize.height, contentMode: .fit).frame(maxWidth: 340).clipShape(RoundedRectangle(cornerRadius: 18)).frame(maxWidth: .infinity) }.padding(18).nativeThemeCard()
                VStack(spacing: 0) {
                    HStack { Text("原文语言").font(.subheadline.bold()); Spacer(); Picker("原文语言", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: false)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled(!installedLanguages.sources.contains($0)) } }.labelsHidden().disabled(model.isRunning) }.padding(18)
                    Divider().padding(.horizontal, 18)
                    HStack { Text("译成").font(.subheadline.bold()); Spacer(); Picker("目标语言", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }.labelsHidden().tint(.cyan).disabled(model.isRunning) }.padding(18)
                    Divider().padding(.horizontal, 18)
                    Button { showAudioSource = true } label: { HStack { Text("音频来源"); Spacer(); Text(model.audioSource.rawValue).foregroundStyle(.secondary); Image(systemName: "chevron.right") }.padding(18).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(model.isRunning)
                    Divider().padding(.horizontal, 18)
                    Button { showStyle = true } label: { HStack { Text("字幕样式"); Spacer(); Text("\(model.shape.rawValue) · \(model.fontChoice.rawValue) · \(model.display.rawValue)").font(.subheadline).foregroundStyle(.secondary); Image(systemName: "chevron.right") }.padding(18).contentShape(Rectangle()) }.buttonStyle(.plain)
                }.nativeThemeCard()
                TranslationReadinessView(source: model.source, target: model.target, speech: true)
                if !model.isRunning && model.audioSource == .phone {
                    if model.awaitingSystem {
                        VStack(spacing: 8) {
                            voiceMainButton("重新打开系统面板", systemImage: "record.circle", color: .primary) { openVoicePicker() }
                            Button("取消") { model.cancelAwaitingSystem() }.font(.subheadline.weight(.medium))
                        }
                    } else {
                        voiceMainButton("开启字幕", systemImage: "waveform", color: .primary) {
                            if voiceGuideHidden { openVoicePicker() } else { showVoiceGuide = true }
                        }
                    }
                } else {
                    voiceMainButton(model.isRunning ? "关闭字幕" : "开启字幕",
                                    systemImage: model.isRunning ? "stop.fill" : "waveform",
                                    color: .primary, filled: !model.isRunning) {
                        model.isRunning ? model.stop() : model.start()
                    }
                }
                if model.isRunning { HStack { Button(model.isPaused ? "恢复" : "暂停") { model.isPaused ? model.resume() : model.pause() }; if model.audioSource == .phone { Spacer(); Text("系统广播").font(.footnote); BroadcastPicker().frame(width: 48, height: 48) } }.padding(.horizontal, 10) }
                if model.isRunning {
                    Button { showLive = true } label: { Label("查看实时记录", systemImage: "text.bubble").frame(maxWidth: .infinity, alignment: .leading).padding(18).nativeThemeCard() }
                }
                if !model.current.isEmpty || !model.lines.isEmpty { Button { showStyle = true } label: { VoiceCaptionPreview(model: model) }.buttonStyle(.plain).accessibilityLabel("调整字幕样式") }
                Button { showHistory = true } label: { Label("字幕记录", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, alignment: .leading).padding(18).nativeThemeCard() }
                Button { showHelp = true } label: { Label("使用说明", systemImage: "questionmark.circle").frame(maxWidth: .infinity, alignment: .leading).padding(18).nativeThemeCard() }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }

    }

    private func openVoicePicker() {
        Task { @MainActor in
            let check = await model.preflightPhoneStart()
            guard check.error == nil else { return }
            model.beginAwaitingSystem()
            voicePickerTrigger += 1
        }
    }

    private func voiceMainButton(_ text: String, systemImage: String, color: Color, filled: Bool = true,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: systemImage).font(.headline)
                .foregroundStyle(filled ? Color.white : color)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(filled ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)),
                            in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
    private var themeFourLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text("随时听，随时翻译").font(.caption).foregroundStyle(.secondary); Text("语音翻译").font(.system(size: 27, weight: .bold)) }; Spacer(); Image(systemName: "waveform").frame(width: 50, height: 50).background(Color(red: 0.78, green: 0.71, blue: 0.91), in: Circle()).foregroundStyle(.black) }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { VStack(alignment: .leading, spacing: 5) { Text("实时字幕").font(.title2.bold()); Text(model.message).font(.caption) }; Spacer(); Image(systemName: "waveform.circle").font(.largeTitle) }
                    PiPSourceView(controller: model.pip).overlay { PiPActiveCover(pip: model.pip) }.aspectRatio(model.subtitleSize.width / model.subtitleSize.height, contentMode: .fit).frame(maxWidth: 340).clipShape(RoundedRectangle(cornerRadius: 18)).frame(maxWidth: .infinity)
                    if !model.isRunning && model.audioSource == .phone {
                        ZStack { Text("开启字幕").font(.headline).frame(maxWidth: .infinity).padding(13).foregroundStyle(.white).background(.black, in: Capsule()); VoiceBroadcastStartPicker { model.beginAwaitingSystem() } }.frame(height: 48)
                    } else { Button(model.isRunning ? "关闭字幕" : "开启字幕") { model.isRunning ? model.stop() : model.start() }.font(.headline).frame(maxWidth: .infinity).padding(13).foregroundStyle(.white).background(.black, in: Capsule()) }
                }.padding(20).foregroundStyle(.black).themeFourCard(Color(red: 0.86, green: 0.64, blue: 0.92))
                TranslationReadinessView(source: model.source, target: model.target, speech: true)
                Text("语音设置").font(.title3.bold())
                VStack(spacing: 0) {
                    HStack { Text("原文语言"); Spacer(); Picker("原文语言", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: false)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled(!installedLanguages.sources.contains($0)) } }.labelsHidden().disabled(model.isRunning) }.padding(16)
                    Divider().padding(.horizontal, 16)
                    HStack { Text("译成"); Spacer(); Picker("目标语言", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }.labelsHidden().disabled(model.isRunning) }.padding(16)
                }.themeFourCard()
                HStack(spacing: 12) {
                    Button { showAudioSource = true } label: { VStack(alignment: .leading, spacing: 8) { Image(systemName: "waveform").font(.title3); Text("音频来源").font(.headline); Text(model.audioSource.rawValue).font(.caption); HStack { Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.white).padding(10).background(.black, in: Circle()) } }.frame(maxWidth: .infinity, alignment: .leading).padding(15).foregroundStyle(.black).themeFourCard(Color(red: 0.78, green: 0.71, blue: 0.91)) }.buttonStyle(.plain).disabled(model.isRunning)
                    Button { showStyle = true } label: { VStack(alignment: .leading, spacing: 8) { Image(systemName: "captions.bubble").font(.title3); Text("字幕样式").font(.headline); Text("\(model.shape.rawValue) · \(model.display.rawValue)").font(.caption); HStack { Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.white).padding(10).background(.black, in: Circle()) } }.frame(maxWidth: .infinity, alignment: .leading).padding(15).foregroundStyle(.black).themeFourCard(Color(red: 1, green: 0.92, blue: 0.58)) }.buttonStyle(.plain)
                }
                if model.isRunning { HStack { Button(model.isPaused ? "恢复" : "暂停") { model.isPaused ? model.resume() : model.pause() }; if model.audioSource == .phone { Spacer(); Text("系统广播").font(.footnote); BroadcastPicker().frame(width: 48, height: 48) } }.padding(.horizontal, 10) }
                if model.isRunning { Button { showLive = true } label: { Label("查看实时记录", systemImage: "text.bubble").frame(maxWidth: .infinity, alignment: .leading).padding(16).themeFourCard() } }
                if !model.current.isEmpty || !model.lines.isEmpty { Button { showStyle = true } label: { VoiceCaptionPreview(model: model) }.buttonStyle(.plain).accessibilityLabel("调整字幕样式") }
                Button { showHistory = true } label: { HStack { Label("字幕记录", systemImage: "clock.arrow.circlepath").font(.headline); Spacer(); Image(systemName: "arrow.up.right") }.padding(18).themeFourCard() }.buttonStyle(.plain)
                Button { showHelp = true } label: { HStack { Label("使用说明", systemImage: "questionmark.circle").font(.headline); Spacer(); Image(systemName: "arrow.up.right") }.padding(18).themeFourCard() }.buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
    private var themeThreeLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { VStack(alignment: .leading, spacing: 5) { Text("语音翻译").font(.system(size: 28, weight: .medium, design: .rounded)); Text("实时听懂身边的声音").font(.subheadline).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "waveform").font(.title3).frame(width: 48, height: 48).background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle()) }.padding(.top, 8)
                VStack(alignment: .leading, spacing: 14) {
                    HStack { VStack(alignment: .leading, spacing: 5) { Text("实时字幕").font(.title3.weight(.medium)); Text(model.message).font(.caption).opacity(0.9) }; Spacer(); Circle().fill(model.isRunning ? .green : .white.opacity(0.7)).frame(width: 8, height: 8) }
                    PiPSourceView(controller: model.pip).overlay { PiPActiveCover(pip: model.pip) }.aspectRatio(model.subtitleSize.width / model.subtitleSize.height, contentMode: .fit).frame(maxWidth: 340).clipShape(RoundedRectangle(cornerRadius: 20)).frame(maxWidth: .infinity)
                }.padding(22).foregroundStyle(.white).themeThreeCard(true)
                TranslationReadinessView(source: model.source, target: model.target, speech: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("语音设置").font(.headline).padding([.horizontal, .top], 18)
                    HStack { Text("原文语言"); Spacer(); Picker("原文语言", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: false)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled(!installedLanguages.sources.contains($0)) } }.labelsHidden().disabled(model.isRunning) }.padding(16)
                    Divider().padding(.horizontal, 16)
                    HStack { Text("译成"); Spacer(); Picker("目标语言", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }.labelsHidden().disabled(model.isRunning) }.padding(16)
                    Divider().padding(.horizontal, 16)
                    Button { showAudioSource = true } label: { HStack { Text("音频来源"); Spacer(); Text(model.audioSource.rawValue).foregroundStyle(.secondary); Image(systemName: "chevron.right") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(model.isRunning)
                    Divider().padding(.horizontal, 16)
                    Button { showStyle = true } label: { HStack { Text("字幕样式"); Spacer(); Text("\(model.shape.rawValue) · \(model.fontChoice.rawValue) · \(model.display.rawValue)").font(.subheadline).foregroundStyle(.secondary); Image(systemName: "chevron.right") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain)
                }.themeThreeCard()
                if !model.isRunning && model.audioSource == .phone {
                    ZStack { Text("开启字幕").font(.headline).frame(maxWidth: .infinity).padding().foregroundStyle(.white).background(.black, in: Capsule()); VoiceBroadcastStartPicker { model.beginAwaitingSystem() } }.frame(height: 54)
                } else {
                    Button(model.isRunning ? "关闭字幕" : "开启字幕") { model.isRunning ? model.stop() : model.start() }.font(.headline).frame(maxWidth: .infinity).padding().foregroundStyle(.white).background(.black, in: Capsule())
                }
                if model.isRunning { HStack { Button(model.isPaused ? "恢复" : "暂停") { model.isPaused ? model.resume() : model.pause() }; if model.audioSource == .phone { Spacer(); Text("系统广播").font(.footnote); BroadcastPicker().frame(width: 48, height: 48) } }.padding(.horizontal, 10) }
                if model.isRunning { Button { showLive = true } label: { Label("查看实时记录", systemImage: "text.bubble").frame(maxWidth: .infinity, alignment: .leading).padding(16).themeThreeCard() } }
                if !model.current.isEmpty || !model.lines.isEmpty { Button { showStyle = true } label: { VoiceCaptionPreview(model: model) }.buttonStyle(.plain).accessibilityLabel("调整字幕样式") }
                Button { showHistory = true } label: { HStack { Image(systemName: "clock.arrow.circlepath").frame(width: 44, height: 44).background(Color.primary.opacity(0.06), in: Circle()); Text("字幕记录").font(.headline); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(16).themeThreeCard() }.buttonStyle(.plain)
                Button { showHelp = true } label: { HStack { Image(systemName: "questionmark.circle").frame(width: 44, height: 44).background(Color.primary.opacity(0.06), in: Circle()); Text("使用说明").font(.headline); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(16).themeThreeCard() }.buttonStyle(.plain)
                Text("手机声音需要系统屏幕共享；受保护内容可能无法获取。") .font(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 30)
        }
    }
    private var warmLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "waveform").font(.title3).padding(12).clearGlass(25)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("语音翻译").font(.headline)
                        Text(model.isRunning ? "字幕正在运行" : "准备就绪").font(.caption).opacity(0.8)
                    }
                    Spacer()
                    Circle().fill(model.isRunning ? .green : .white.opacity(0.5)).frame(width: 8, height: 8)
                }.padding(18).clearGlass(28)
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("实时字幕").font(.headline); Spacer(); Text(model.audioSource.rawValue).font(.caption).opacity(0.8) }
                    Text(model.message).font(.footnote).opacity(0.85)
                    PiPSourceView(controller: model.pip).overlay { PiPActiveCover(pip: model.pip) }
                        .aspectRatio(model.subtitleSize.width / model.subtitleSize.height, contentMode: .fit)
                        .frame(maxWidth: 340).clipShape(RoundedRectangle(cornerRadius: 18)).frame(maxWidth: .infinity)
                }.padding(20).clearGlass(28)
                TranslationReadinessView(source: model.source, target: model.target, speech: true)
                VStack(spacing: 0) {
                    HStack { Label("原文语言", systemImage: "globe"); Spacer(); Picker("原文语言", selection: $model.source) { ForEach(installedLanguages.sourceOptions(current: model.source, auto: false)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled(!installedLanguages.sources.contains($0)) } }.labelsHidden().disabled(model.isRunning) }.padding(16)
                    Divider().overlay(.white.opacity(0.15))
                    HStack { Label("翻译成", systemImage: "translate"); Spacer(); Picker("目标语言", selection: $model.target) { ForEach(installedLanguages.targetOptions(current: model.target)) { Text(installedLanguages.targetLabel($0)).tag($0).disabled(!installedLanguages.targets.contains($0)) } }.labelsHidden().disabled(model.isRunning) }.padding(16)
                    Divider().overlay(.white.opacity(0.15))
                    Button { showAudioSource = true } label: { HStack { Label("音频来源", systemImage: "waveform"); Spacer(); Text(model.audioSource.rawValue).opacity(0.8); Image(systemName: "chevron.right") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(model.isRunning)
                    Divider().overlay(.white.opacity(0.15))
                    Button { showStyle = true } label: { HStack { Label("字幕样式", systemImage: "captions.bubble"); Spacer(); Text("\(model.shape.rawValue) · \(model.fontChoice.rawValue) · \(model.display.rawValue)").font(.subheadline).opacity(0.8); Image(systemName: "chevron.right") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain)
                }.clearGlass(26)
                if !model.isRunning && model.audioSource == .phone {
                    ZStack {
                        Text("开启字幕").font(.headline).frame(maxWidth: .infinity).padding().background(Color(red: 1, green: 0.47, blue: 0.39).opacity(0.55), in: Capsule()).clearGlass(30)
                        VoiceBroadcastStartPicker { model.beginAwaitingSystem() }
                    }.frame(height: 54)
                } else {
                    Button(model.isRunning ? "关闭字幕" : "开启字幕") { model.isRunning ? model.stop() : model.start() }
                        .font(.headline).frame(maxWidth: .infinity).padding().background(Color(red: 1, green: 0.47, blue: 0.39).opacity(0.5), in: Capsule()).clearGlass(30)
                }
                if model.isRunning {
                    HStack { Button(model.isPaused ? "恢复" : "暂停") { model.isPaused ? model.resume() : model.pause() }; if model.audioSource == .phone { Spacer(); Text("系统广播").font(.footnote); BroadcastPicker().frame(width: 48, height: 48) } }.padding(.horizontal, 10)
                }
                if model.isRunning { Button { showLive = true } label: { Label("查看实时记录", systemImage: "text.bubble").frame(maxWidth: .infinity, alignment: .leading).padding(16).clearGlass(24) } }
                if !model.current.isEmpty || !model.lines.isEmpty { Button { showStyle = true } label: { VoiceCaptionPreview(model: model) }.buttonStyle(.plain).accessibilityLabel("调整字幕样式") }
                Button { showHistory = true } label: { HStack { Image(systemName: "clock.arrow.circlepath").padding(12).clearGlass(24); Text("字幕记录"); Spacer(); Image(systemName: "chevron.right") }.padding(14).clearGlass(24) }.buttonStyle(.plain)
                Button { showHelp = true } label: { HStack { Image(systemName: "questionmark.circle").padding(12).clearGlass(24); Text("使用说明"); Spacer(); Image(systemName: "chevron.right") }.padding(14).clearGlass(24) }.buttonStyle(.plain)
                Text("手机声音需要系统屏幕共享；受保护内容可能无法获取。画中画大小由 iOS 控制。") .font(.footnote).opacity(0.8)
            }.padding(.horizontal, 20).padding(.bottom, 24).foregroundStyle(.white)
        }
    }
}

private struct VoiceLiveView: View {
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    private var mist: Bool { visualTheme == 5 }
    @ObservedObject var model: VoiceModel
    @Environment(\.dismiss) private var dismiss
    @State private var showHistory = false
    @State private var showStyle = false
    @State private var finished = false
    @State private var followLatest = true
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
        if finished {
            NavigationStack {
                if let initial = model.completedSession {
                    let current = model.sessions.first(where: { $0.id == initial.id }) ?? initial
                    VoiceSessionDetail(session: current, model: model) { model.delete(current.id) }
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } } }
                } else {
                    ContentUnavailableView("本次没有识别到文字", systemImage: "text.bubble")
                        .mistSheet()
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } } }
                }
            }
        } else {
        VStack(spacing: 0) {
            // Header: back · ● 正在收音 00:05 ▮▮▮ / 语言方向 / 小窗提示
            ZStack {
                HStack {
                    if mist {
                        MistCircleButton(systemImage: "chevron.left", size: 42, label: "返回") { dismiss() }
                    } else {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.body.weight(.semibold))
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Circle().fill(model.isPaused ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(model.isPaused ? "已暂停" : "正在收音")
                        .font(mist ? .system(size: 16, weight: .light).italic() : .subheadline.weight(.semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.elapsedLabel(at: context.date))
                            .font(mist ? Mist.light(16) : .subheadline).monospacedDigit()
                            .foregroundStyle(mist ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    }
                    VoiceLevelMeter(level: model.level, paused: model.isPaused)
                }
                .foregroundStyle(mist ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            }
            if mist {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(model.source.mistCode).font(Mist.thin(40))
                    Text("→ \(model.target.rawValue)").font(Mist.thin(18)).opacity(0.85)
                    Spacer()
                    Text("\(model.conversationLines.count) 句 · \(model.conversationLines.reduce(0) { $0 + $1.original.count }) 字")
                        .font(Mist.light(13)).opacity(0.85)
                }
                .foregroundStyle(.white).padding(.top, 10).padding(.horizontal, 4)
            } else {
                Text("\(model.source.rawValue) → \(model.target.rawValue)")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            Label("切到其他 App 时，字幕会在小窗里继续显示。", systemImage: "pip")
                .font(mist ? Mist.light(12) : .caption2)
                .foregroundStyle(mist ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .padding(.top, 4)

            // Transcript: every sentence stays; new ones push the text upwards.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.conversationLines.isEmpty {
                            Text("开始讲话，字幕会显示在这里。")
                                .font(mist ? Mist.light(16) : .body).foregroundStyle(mist ? Mist.inkSoft : .secondary)
                        }
                        ForEach(model.conversationLines) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.original).font(mist ? Mist.light(14) : .footnote)
                                    .foregroundStyle(mist ? Mist.inkSoft : .secondary)
                                    .textSelection(.enabled)
                                if !line.translated.isEmpty {
                                    Text(line.translated)
                                        .font(.system(size: mist ? 19 : 17, weight: mist ? .regular : .semibold))
                                        .foregroundStyle(mist ? Mist.ink : .primary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("voice-live-bottom")
                    }
                    .frame(maxWidth: .infinity, minHeight: 0, alignment: .bottomLeading)
                    .padding(.vertical, 12)
                    // Text revisions must not animate or re-flow the list.
                    .transaction { $0.animation = nil }
                }
                .scrollIndicators(.hidden)
                // Keeps the view pinned to the newest line while text grows.
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 120
                } action: { _, atBottom in
                    followLatest = atBottom
                }
                // Follow new text only while the reader is at the bottom; after
                // scrolling up, a "回到最新" button appears instead of a jump.
                .onChange(of: model.conversationLines.last.map { $0.original.count + $0.translated.count }) { _, _ in
                    guard followLatest else { return }
                    proxy.scrollTo("voice-live-bottom", anchor: .bottom)
                }
                .onChange(of: model.conversationLines.count) { _, _ in
                    guard followLatest else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("voice-live-bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !followLatest && !model.conversationLines.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("voice-live-bottom", anchor: .bottom) }
                            followLatest = true
                        } label: {
                            Label("回到最新", systemImage: "arrow.down").font(.caption.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, mist ? 20 : 0)
            .background {
                if mist {
                    RoundedRectangle(cornerRadius: 40, style: .continuous).fill(Mist.porcelain)
                        .shadow(color: Color(red: 0.22, green: 0.27, blue: 0.36).opacity(0.16), radius: 26, y: 14)
                }
            }
            .padding(.top, mist ? 14 : 0)

            // Bottom bar: 大小 · ■ 结束 · 记录
            if mist {
                HStack(spacing: 12) {
                    MistCircleButton(systemImage: "textformat.size", size: 54, label: "字幕大小") { showStyle = true }
                    Button { model.stop(); finished = true } label: {
                        MistPrimaryLabel(title: "结束并保存", systemImage: "stop.fill")
                    }.buttonStyle(.plain)
                    MistCircleButton(systemImage: "text.bubble", size: 54, label: "字幕记录") { showHistory = true }
                }
                .padding(.top, 14)
            } else {
            HStack(spacing: 14) {
                Button { showStyle = true } label: {
                    Text("大小").font(.subheadline.weight(.semibold))
                        .frame(width: 50, height: 50)
                        .glassEffect(.regular.interactive(), in: Circle())
                }.buttonStyle(.plain)
                Button { model.stop(); finished = true } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.red).frame(width: 11, height: 11)
                        Text("结束").font(.headline)
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }.buttonStyle(.plain)
                Button { showHistory = true } label: {
                    Image(systemName: "text.bubble").font(.body.weight(.semibold))
                        .frame(width: 50, height: 50)
                        .glassEffect(.regular.interactive(), in: Circle())
                }.buttonStyle(.plain)
            }
            .padding(.top, 8)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            .background {
                if mist { MistBackground() } else { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
            }
            .environment(\.colorScheme, mist ? .light : colorScheme)
            .sheet(isPresented: $showStyle) { VoiceStyleView(model: model) }
            .sheet(isPresented: $showHistory) { VoiceHistoryView(model: model) }
        }
        }
        .font(.body)
        .foregroundStyle(.primary)
        .tint(mist ? Mist.ink : .blue)
    }
}

/// Small animated level bars next to the timer, like a recording indicator.
private struct VoiceLevelMeter: View {
    @ObservedObject var level: VoiceLevel
    var paused: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.green.opacity(paused ? 0.3 : 0.9))
                    .frame(width: 3, height: paused ? 4 : CGFloat(4 + (level.bucket > index ? 3 + index * 2 : 0)))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: level.bucket)
        .accessibilityHidden(true)
    }
}

private struct VoiceHelpView: View {
    @Environment(\.dismiss) private var dismiss
    private let steps = [
        ("1", "选择讲话语言", "先选英语、日语等原文语言；目标语言可选择已支持的语种。"),
        ("2", "选择音频来源", "身边讲话使用麦克风；手机声音需要开启青译系统屏幕共享。"),
        ("3", "开启字幕", "手机声音：在系统面板开始直播后，请留在本页等待画中画出现，再切换其他 App。身边讲话先在本页查看记录。"),
        ("4", "关闭并查看记录", "点关闭字幕可结束识别和画中画；自动保存时可查看本机记录。")
    ]
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    var body: some View {
        if visualTheme == 5 {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    MistSheetHeader(title: "语音翻译怎么用") { dismiss() }
                    MistStepsCard(steps: steps.map { (title: $0.1, detail: $0.2) })
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)
            .background(MistBackground())
            .environment(\.colorScheme, .light)
            .presentationBackground { MistBackground() }
            .presentationCornerRadius(38)
        } else {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text(step.0).font(.headline).frame(width: 30, height: 30)
                                .background(.green.opacity(0.15), in: Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                Text(step.1).font(.headline)
                                Text(step.2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding().clearGlass(18)
                    }
                }.padding()
            }
            .background(GlassWallpaper())
            .navigationTitle("语音翻译说明")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            } }
        }
        }
    }
}

// The settings preview and the AVSampleBuffer PiP use identical pixels,
// font fitting, wrapping and source/translation layout.
@MainActor enum VoiceCaptionRenderer {
    static func image(original: String, translated: String,
                      previousOriginal: String, previousTranslated: String,
                      size: CGSize, shape: VoiceSubtitleShape,
                      display: VoiceSubtitleDisplay, font: VoiceSubtitleFont,
                      backgroundOpacity: Double, backgroundBrightness: Double, subtitleColorHex: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let shade = CGFloat(min(0.35, max(0, backgroundBrightness)))
            UIColor(white: shade, alpha: CGFloat(min(1, max(0.1, backgroundOpacity)))).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let textColor = UIColor(red: CGFloat((subtitleColorHex >> 16) & 255) / 255, green: CGFloat((subtitleColorHex >> 8) & 255) / 255, blue: CGFloat(subtitleColorHex & 255) / 255, alpha: 1)
            let inset: CGFloat = shape == .adaptive ? 18 : 30
            let bounds = CGRect(x: inset, y: 14, width: size.width - 2 * inset,
                                height: size.height - 28)
            let base: CGFloat = font == .small ? 40 : font == .large ? 65 : 52
            let groups: [(String, String)] = shape == .horizontal || shape == .card
                ? [(previousOriginal, previousTranslated), (original, translated)]
                : [(original, translated)]
            let valid = groups.filter { !$0.0.isEmpty || !$0.1.isEmpty }
            if valid.isEmpty || (valid.count == 1 && valid[0].0 == "等待讲话") {
                if valid.isEmpty || valid[0].0 == "等待讲话" {
                    for (index, fraction) in [0.72, 0.52, 0.34].enumerated() {
                        let bar = CGRect(x: bounds.minX, y: bounds.midY - 36 + CGFloat(index) * 30,
                                         width: bounds.width * fraction, height: 10)
                        UIColor.white.withAlphaComponent(0.28).setFill()
                        UIBezierPath(roundedRect: bar, cornerRadius: 5).fill()
                    }
                } else {
                    draw("没听到声音", in: bounds, size: base * 0.75, weight: .medium,
                         color: .white, alignment: .center, maxLines: 1)
                }
                return
            }
            let gap: CGFloat = shape == .card ? 20 : 12
            let count = CGFloat(valid.count)
            let height = max(1, (bounds.height - gap * (count - 1)) / count)
            for (index, pair) in valid.enumerated() {
                let region = CGRect(x: bounds.minX, y: bounds.minY + CGFloat(index) * (height + gap),
                                    width: bounds.width, height: height)
                let source = pair.0.trimmingCharacters(in: .whitespacesAndNewlines)
                let target = pair.1.trimmingCharacters(in: .whitespacesAndNewlines)
                let mini = shape == .adaptive
                let primary = display == .original ? source : (target.isEmpty ? source : target)
                let secondary = display == .bilingual && !mini && !target.isEmpty ? source : ""
                let alignment: NSTextAlignment = mini || display != .bilingual ? .center : .left
                let secondaryHeight: CGFloat = secondary.isEmpty ? 0 : min(65, region.height * 0.32)
                if !secondary.isEmpty {
                    draw(secondary, in: CGRect(x: region.minX, y: region.minY,
                         width: region.width, height: secondaryHeight),
                         size: base * 0.48, weight: .regular,
                         color: textColor.withAlphaComponent(0.7),
                         alignment: alignment, maxLines: shape == .card ? 2 : 1)
                }
                draw(primary, in: CGRect(x: region.minX, y: region.minY + secondaryHeight,
                     width: region.width, height: region.height - secondaryHeight),
                     size: mini ? base * 1.05 : base, weight: .semibold,
                     color: textColor, alignment: alignment,
                     maxLines: mini ? 1 : shape == .card ? 3 : shape == .strip ? 2 : 2)
            }
        }
    }

    private static func draw(_ text: String, in rect: CGRect, size: CGFloat,
                             weight: UIFont.Weight, color: UIColor,
                             alignment: NSTextAlignment, maxLines: Int) {
        guard rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let content = text as NSString
        var pointSize = size
        while pointSize > 18 {
            let typeface = UIFont.systemFont(ofSize: pointSize, weight: weight)
            let measured = content.boundingRect(with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: typeface, .paragraphStyle: paragraph], context: nil)
            if measured.height <= rect.height && measured.height <= CGFloat(maxLines) * typeface.lineHeight * 1.1 { break }
            pointSize -= 2
        }
        content.draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: pointSize, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph])
    }

}

private struct VoiceCaptionPreview: View {
    @ObservedObject var model: VoiceModel
    var body: some View {
        Image(uiImage: VoiceCaptionRenderer.image(
            original: model.stylePreviewOriginal, translated: model.stylePreviewTranslation,
            previousOriginal: model.stylePreviewPreviousOriginal,
            previousTranslated: model.stylePreviewPreviousTranslation,
            size: model.subtitleSize, shape: model.shape, display: model.display,
            font: model.fontChoice, backgroundOpacity: model.backgroundOpacity,
            backgroundBrightness: model.backgroundBrightness, subtitleColorHex: model.subtitleColorHex))
            .resizable()
            .aspectRatio(model.subtitleSize.width / model.subtitleSize.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel(model.display == .original ? model.stylePreviewOriginal
                                : model.stylePreviewTranslation)
    }
}

struct VoiceStyleView: View {
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @ObservedObject var model: VoiceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VoiceCaptionPreview(model: model).frame(maxHeight: 125).padding(.horizontal).padding(.top, 8)
                Text(model.isRunning ? "当前字幕 · 与画中画相同排版" : "样式预览 · 与画中画相同排版")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("形状").font(.headline)
                    HStack(spacing: 8) {
                        ForEach(VoiceSubtitleShape.allCases) { value in
                            Button { model.selectShape(value) } label: {
                                VStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.black.opacity(0.85))
                                        .frame(height: value == .card ? 45 : value == .horizontal ? 38 : value == .strip ? 27 : 15)
                                    Text(value.rawValue).font(.subheadline.bold())
                                    Text(value == .strip ? "双语2行" : value == .horizontal ? "两段4行" : value == .card ? "最多8行" : "单语1行")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity).frame(height: 112)
                                .padding(5)
                                .clearGlass(14)
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(model.shape == value ? (visualTheme == 5 ? Mist.ink : .green) : .clear,
                                            lineWidth: visualTheme == 5 ? 1.2 : 2))
                            }.foregroundStyle(.primary)
                        }
                    }
                    Text("字号").font(.headline)
                    Picker("字号", selection: $model.fontChoice) {
                        ForEach(VoiceSubtitleFont.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("显示").font(.headline)
                    Picker("显示", selection: $model.display) {
                        ForEach(VoiceSubtitleDisplay.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    ColorPicker("字幕文字颜色", selection: Binding(get: {
                        Color(red: Double((model.subtitleColorHex >> 16) & 255) / 255, green: Double((model.subtitleColorHex >> 8) & 255) / 255, blue: Double(model.subtitleColorHex & 255) / 255)
                    }, set: { color in
                        let uiColor = UIColor(color)
                        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
                        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
                        model.subtitleColorHex = (Int(red * 255) << 16) | (Int(green * 255) << 8) | Int(blue * 255)
                    }), supportsOpacity: false)
                    Button("恢复默认白色") { model.subtitleColorHex = 0xffffff }.font(.footnote)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("字幕背景透明度")
                        Slider(value: $model.backgroundOpacity, in: 0.1...1.0)
                        Text("字幕背景亮度")
                        Slider(value: $model.backgroundBrightness, in: 0...0.35)
                        Text("画中画透明显示由 iOS 决定；滑块改变字幕画布的背景绘制。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding().clearGlass(18)
                    VStack(alignment: .leading) {
                        Text("字幕画面宽度")
                        Slider(value: Binding(get: {
                            model.customWidth > 0 ? model.customWidth : model.shape.defaultSize.width
                        }, set: { model.customWidth = $0 }), in: 420...1100)
                        Text("字幕画面高度")
                        Slider(value: Binding(get: {
                            model.subtitleSize.height
                        }, set: { model.customHeight = $0 }), in: 100...460)
                        Text("可调整字幕视频的长宽比例；实际画中画尺寸和缩放档位由 iOS 决定。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding().clearGlass(18)
                }.padding()
            }
            }
            .background(GlassWallpaper())
            .navigationTitle("字幕样式")
            .mistSheet()
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            } }
        }
    }
}

private struct VoiceHistoryView: View {
    @ObservedObject var model: VoiceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(model.sessions) { session in
                    NavigationLink {
                        VoiceSessionDetail(session: session, model: model) { model.delete(session.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            Text("\(session.source) → \(session.target ?? "简体中文")").font(.headline)
                            Text(session.lines.first?.translated ?? "").lineLimit(1)
                            Text("\(session.lines.count) 句 · \(Int(session.duration)) 秒 · \(session.audioSource.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.sessions[$0].id }
                    for id in ids { model.delete(id) }
                }
                Text("字幕文字只保存在这台设备上，不保存原始录音。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                .background(GlassWallpaper())
                .navigationTitle("字幕记录")
                .mistSheet()
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            } }
        }
    }
}

private struct VoiceSessionDetail: View {
    let session: VoiceSession
    @ObservedObject var model: VoiceModel
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repairing = false
    @State private var repairMessage = ""
    @State private var copied = false
    private var displayed: VoiceSession { model.sessions.first(where: { $0.id == session.id }) ?? (model.completedSession?.id == session.id ? model.completedSession : nil) ?? session }
    var body: some View {
        List {
            HStack {
                Button(copied ? "已复制" : "复制全部") { UIPasteboard.general.string = displayed.exportText; copied = true }
                Spacer()
                ShareLink("导出", item: displayed.exportText)
            }.buttonStyle(.borderless)
            Button(repairing ? "正在重新翻译…" : "重新翻译完整记录") {
                repairing = true; repairMessage = ""
                Task { do { try await model.retranslateRecord(session.id); repairMessage = "重新翻译完成" } catch { repairMessage = "重新翻译失败：\(error.localizedDescription)" }; repairing = false }
            }.disabled(repairing)
            if !repairMessage.isEmpty { Text(repairMessage).font(.footnote).foregroundStyle(.secondary) }
            ForEach(displayed.lines) { line in
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(format: "%02d:%02d",
                        max(0, Int(line.date.timeIntervalSince(displayed.date))) / 60,
                        max(0, Int(line.date.timeIntervalSince(displayed.date))) % 60))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(line.original).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(line.translated).textSelection(.enabled)
                }
                .contextMenu {
                    Button("复制原文") { UIPasteboard.general.string = line.original }
                    Button("复制译文") { UIPasteboard.general.string = line.translated }
                }
            }
            Button("删除这场记录", role: .destructive) {
                onDelete()
                dismiss()
            }
        }
        .scrollContentBackground(.hidden)
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                .background(GlassWallpaper())
                .navigationTitle(session.date.formatted(date: .abbreviated, time: .shortened))
                .mistSheet()
    }
}
