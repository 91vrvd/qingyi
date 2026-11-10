import Foundation
import SwiftUI
import MLKitTranslate

/// Fast on-device translation for live screen translation (Google ML Kit).
/// Measured on device, Apple Translation handled ~130 characters per second
/// (a full English screen took 7–9 s). ML Kit runs a smaller offline model.
/// Models (~30 MB per language) are downloaded once, then everything runs
/// locally. Whenever ML Kit is not ready or fails, nil is returned and the
/// caller falls back to Apple Translation, so nothing is ever left untranslated.
@MainActor final class MLKitEngine {
    static let shared = MLKitEngine()

    private var translators: [String: Translator] = [:]
    private var ready: Set<String> = []
    private var downloading: Set<String> = []
    private var lastFailure: [String: Date] = [:]
    private(set) var statusText = "未准备"

    static func language(_ code: String) -> TranslateLanguage? {
        switch code {
        case "zh", "zh-Hans": return .chinese
        case "en": return .english
        case "ja": return .japanese
        case "ko": return .korean
        case "fr": return .french
        case "de": return .german
        case "es": return .spanish
        case "it": return .italian
        case "pt": return .portuguese
        case "ru": return .russian
        case "ar": return .arabic
        case "th": return .thai
        case "vi": return .vietnamese
        case "id": return .indonesian
        default: return nil
        }
    }

    /// True when the fast engine is selected and both language models are on
    /// the device, i.e. this pair can be translated without Apple's pack.
    func canServe(source: String, target: String) -> Bool {
        guard Self.preferFast, let s = Self.language(source), let t = Self.language(target), s != t else { return false }
        let manager = ModelManager.modelManager()
        return manager.isModelDownloaded(TranslateRemoteModel.translateRemoteModel(language: s))
            && manager.isModelDownloaded(TranslateRemoteModel.translateRemoteModel(language: t))
    }

    /// Called after a model is downloaded or deleted in Settings, so the next
    /// translation re-checks the pair immediately instead of waiting.
    func modelsChanged() {
        ready.removeAll()
        lastFailure.removeAll()
        statusText = "已更新离线模型"
    }

    static func modelDownloaded(_ code: String?) -> Bool {
        guard let code, let language = language(code) else { return false }
        return ModelManager.modelManager().isModelDownloaded(
            TranslateRemoteModel.translateRemoteModel(language: language))
    }

    /// Starts downloading the given languages' models (skips ones on the device).
    static func downloadModels(_ codes: [String?]) {
        let conditions = ModelDownloadConditions(allowsCellularAccess: true, allowsBackgroundDownloading: true)
        for code in codes {
            guard let code, let language = language(code), !modelDownloaded(code) else { continue }
            _ = ModelManager.modelManager().download(
                TranslateRemoteModel.translateRemoteModel(language: language), conditions: conditions)
            qyLog("mlkit first-run download \(code) started")
        }
    }

    /// Install the hook used by LocalTranslator.translateBatch.
    static func install() {
        LocalTranslator.fastEngine = { texts, source, target in
            await MLKitEngine.shared.translate(texts, source: source, target: target)
        }
    }

    /// Settings key: "fast" (ML Kit, default) or "apple" (Apple Translation).
    static let engineKey = "qingyiTranslationEngine"
    static var preferFast: Bool {
        (UserDefaults.standard.string(forKey: engineKey) ?? "fast") == "fast"
    }

    /// Start (or confirm) the model download for a pair ahead of use.
    func prepare(source: String, target: String) {
        guard Self.preferFast, let pair = pairKey(source, target) else { return }
        _ = translator(for: pair, source: source, target: target)
    }

    private func pairKey(_ source: String, _ target: String) -> String? {
        guard let s = Self.language(source), let t = Self.language(target), s != t else { return nil }
        return "\(s.rawValue)|\(t.rawValue)"
    }

    private func translator(for pair: String, source: String, target: String) -> Translator? {
        guard let s = Self.language(source), let t = Self.language(target) else { return nil }
        let translator: Translator
        if let existing = translators[pair] {
            translator = existing
        } else {
            translator = Translator.translator(options: TranslatorOptions(sourceLanguage: s, targetLanguage: t))
            translators[pair] = translator
        }
        if !ready.contains(pair) && !downloading.contains(pair) {
            if let failed = lastFailure[pair], Date().timeIntervalSince(failed) < 20 { return translator }
            downloading.insert(pair)
            statusText = "正在准备离线模型 \(pair)"
            let started = Date()
            let conditions = ModelDownloadConditions(allowsCellularAccess: true, allowsBackgroundDownloading: true)
            translator.downloadModelIfNeeded(with: conditions) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloading.remove(pair)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    if let error {
                        self.lastFailure[pair] = Date()
                        self.statusText = "离线模型下载失败：\(error.localizedDescription)"
                        qyLog("mlkit model \(pair) failed after \(ms)ms: \(error.localizedDescription)")
                    } else {
                        self.ready.insert(pair)
                        self.statusText = "离线模型就绪 \(pair)"
                        qyLog("mlkit model \(pair) ready after \(ms)ms")
                    }
                }
            }
        }
        return translator
    }

    /// Translate texts in order. Returns nil when ML Kit cannot serve this pair
    /// right now (model still downloading, unsupported, or any error).
    func translate(_ texts: [String], source: String, target: String) async -> [String]? {
        // Settings → 翻译引擎: "apple" means the user prefers accuracy.
        guard Self.preferFast else { return nil }
        guard let pair = pairKey(source, target),
              let translator = translator(for: pair, source: source, target: target) else { return nil }
        if !ready.contains(pair), let s = Self.language(source), let t = Self.language(target) {
            // Models already on the device: usable at once, no need to wait for
            // the downloadModelIfNeeded callback (first voice line / lens tap).
            let manager = ModelManager.modelManager()
            if manager.isModelDownloaded(TranslateRemoteModel.translateRemoteModel(language: s)),
               manager.isModelDownloaded(TranslateRemoteModel.translateRemoteModel(language: t)) {
                ready.insert(pair)
            }
        }
        guard ready.contains(pair) else { return nil }
        let cjkSource = ["zh", "zh-Hans", "ja", "ko", "th"].contains(source)
        let inputs = texts.map { text in
            text.replacingOccurrences(of: "\n", with: cjkSource ? "" : " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var outputs = [String?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, input) in inputs.enumerated() {
                group.addTask { @MainActor in
                    if input.isEmpty { return (index, "") }
                    let result: String? = await withCheckedContinuation { continuation in
                        translator.translate(input) { translated, error in
                            continuation.resume(returning: error == nil ? translated : nil)
                        }
                    }
                    return (index, result)
                }
            }
            for await (index, result) in group { outputs[index] = result }
        }
        guard !outputs.contains(where: { $0 == nil }) else {
            qyLog("mlkit translate had failures, falling back")
            return nil
        }
        return outputs.map { $0 ?? "" }
    }
}

/// Settings page: download / delete ML Kit offline translation models.
/// No API key or account is needed; the first download needs access to
/// Google's download servers, after that translation is fully offline.
struct MLKitModelsView: View {
    private struct Item: Identifiable {
        let id: String
        let name: String
        let language: TranslateLanguage
    }
    private let items: [Item] = [
        Item(id: "zh", name: "中文（目标语言，必需）", language: .chinese),
        Item(id: "en", name: "英语", language: .english),
        Item(id: "ja", name: "日语", language: .japanese),
        Item(id: "ko", name: "韩语", language: .korean),
        Item(id: "fr", name: "法语", language: .french),
        Item(id: "de", name: "德语", language: .german),
        Item(id: "es", name: "西班牙语", language: .spanish),
        Item(id: "it", name: "意大利语", language: .italian),
        Item(id: "pt", name: "葡萄牙语", language: .portuguese),
        Item(id: "ru", name: "俄语", language: .russian),
        Item(id: "ar", name: "阿拉伯语", language: .arabic),
        Item(id: "th", name: "泰语", language: .thai),
        Item(id: "vi", name: "越南语", language: .vietnamese),
        Item(id: "id", name: "印尼语", language: .indonesian),
    ]
    @State private var downloaded: Set<String> = []
    @State private var progress: [String: Progress] = [:]
    @State private var messages: [String: String] = [:]
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var tick = 0

    var body: some View {
        Form {
            Section {
                Text("屏幕实时翻译会优先使用这里的离线模型（谷歌 ML Kit），速度比系统翻译快；没有下载的语言会自动改用系统翻译。")
                Text("无需 API 密钥、账号或付费。每种语言约 30 MB，首次下载需要能访问谷歌服务器（国内网络可能需要开启代理），下载完成后完全离线使用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("语言模型") {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                            Text(statusLine(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let running = progress[item.id], !running.isFinished {
                            ProgressView(value: max(0.02, running.fractionCompleted)).frame(width: 70)
                        } else if downloaded.contains(item.id) {
                            Button("删除", role: .destructive) { delete(item) }.buttonStyle(.borderless)
                        } else {
                            Button("下载") { download(item) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("离线快速翻译模型")
        .mistSheet()
        .onAppear(perform: refresh)
        .onReceive(ticker) { _ in
            tick += 1   // re-render progress bars
            if progress.values.contains(where: { $0.isFinished }) { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mlkitModelDownloadDidSucceed)) { note in
            finish(note, error: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mlkitModelDownloadDidFail)) { note in
            finish(note, error: note.userInfo?[ModelDownloadUserInfoKey.error.rawValue] as? Error)
        }
    }

    private func model(_ item: Item) -> TranslateRemoteModel {
        TranslateRemoteModel.translateRemoteModel(language: item.language)
    }

    private func statusLine(_ item: Item) -> String {
        if let message = messages[item.id] { return message }
        if let running = progress[item.id], !running.isFinished {
            return "下载中 \(Int(running.fractionCompleted * 100))%"
        }
        return downloaded.contains(item.id) ? "已下载，可离线使用" : "未下载"
    }

    private func refresh() {
        let manager = ModelManager.modelManager()
        downloaded = Set(items.filter { manager.isModelDownloaded(model($0)) }.map(\.id))
        for (id, running) in progress where running.isFinished { progress.removeValue(forKey: id) }
    }

    private func download(_ item: Item) {
        messages[item.id] = "正在连接下载服务器…"
        let conditions = ModelDownloadConditions(allowsCellularAccess: true, allowsBackgroundDownloading: true)
        progress[item.id] = ModelManager.modelManager().download(model(item), conditions: conditions)
        qyLog("mlkit settings download \(item.id) started")
    }

    private func delete(_ item: Item) {
        ModelManager.modelManager().deleteDownloadedModel(model(item)) { error in
            messages[item.id] = error.map { "删除失败：\($0.localizedDescription)" }
            MLKitEngine.shared.modelsChanged()
            refresh()
        }
    }

    private func finish(_ note: Notification, error: Error?) {
        guard let remote = note.userInfo?[ModelDownloadUserInfoKey.remoteModel.rawValue] as? TranslateRemoteModel,
              let item = items.first(where: { $0.language == remote.language }) else { return }
        progress.removeValue(forKey: item.id)
        if let error {
            messages[item.id] = "下载失败：\(error.localizedDescription)。请确认能访问谷歌服务器后重试。"
            qyLog("mlkit settings download \(item.id) failed: \(error.localizedDescription)")
        } else {
            messages[item.id] = nil
            qyLog("mlkit settings download \(item.id) succeeded")
        }
        MLKitEngine.shared.modelsChanged()
        refresh()
    }
}
