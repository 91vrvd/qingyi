import Foundation
import UIKit
import Vision
import NaturalLanguage
import Translation

struct TextBlock: Identifiable, Codable {
    var id = UUID()
    var original: String
    var translated: String = ""
    var box: CGRect
    var language: String = ""
}

struct CaptureResult: Codable {
    var timestamp: Date
    var blocks: [TextBlock]
    var status: String
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto = "自动识别"
    case simplifiedChinese = "简体中文"
    case english = "英语"
    case japanese = "日语"
    case korean = "韩语"
    case french = "法语"
    case german = "德语"
    case spanish = "西班牙语"
    case italian = "意大利语"
    case portuguese = "葡萄牙语"
    case russian = "俄语"
    case arabic = "阿拉伯语"
    case thai = "泰语"
    case vietnamese = "越南语"
    case indonesian = "印尼语"
    var id: String { rawValue }
    static var targets: [AppLanguage] { allCases.filter { $0 != .auto } }
    var code: String? {
        switch self {
        case .auto: nil
        case .simplifiedChinese: "zh-Hans"
        case .english: "en"
        case .japanese: "ja"
        case .korean: "ko"
        case .french: "fr"
        case .german: "de"
        case .spanish: "es"
        case .italian: "it"
        case .portuguese: "pt"
        case .russian: "ru"
        case .arabic: "ar"
        case .thai: "th"
        case .vietnamese: "vi"
        case .indonesian: "id"
        }
    }
    var speechLocale: String {
        switch self {
        case .simplifiedChinese: "zh-CN"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        case .french: "fr-FR"
        case .german: "de-DE"
        case .spanish: "es-ES"
        case .italian: "it-IT"
        case .portuguese: "pt-PT"
        case .russian: "ru-RU"
        case .arabic: "ar-SA"
        case .thai: "th-TH"
        case .vietnamese: "vi-VN"
        case .indonesian: "id-ID"
        default: "en-US"
        }
    }
    var sampleText: String {
        switch self {
        case .simplifiedChinese: "你好，最近怎么样？"
        case .auto, .english: "Hello, how are you?"
        case .japanese: "こんにちは、元気ですか。"
        case .korean: "안녕하세요, 잘 지내세요?"
        case .french: "Bonjour, comment allez-vous ?"
        case .german: "Hallo, wie geht es Ihnen?"
        case .spanish: "Hola, ¿cómo estás?"
        case .italian: "Ciao, come stai?"
        case .portuguese: "Olá, como vai você?"
        case .russian: "Здравствуйте, как дела?"
        case .arabic: "مرحبا، كيف حالك؟"
        case .thai: "สวัสดี คุณสบายดีไหม"
        case .vietnamese: "Xin chào, bạn khỏe không?"
        case .indonesian: "Halo, apa kabar?"
        }
    }
}

enum RecognitionService {
    static func recognize(_ image: UIImage) throws -> [TextBlock] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> TextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextBlock(original: text, box: observation.boundingBox)
        }
        // Sort rows first, then sort text within each row. A pairwise y-tolerance
        // comparator is non-transitive and can put the last URL line before its middle.
        var rows: [[TextBlock]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first {
                let overlap = max(0, min(first.box.maxY, line.box.maxY)
                                  - max(first.box.minY, line.box.minY))
                if overlap > min(first.box.height, line.box.height) * 0.5 {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.flatMap { $0.sorted(by: { $0.box.minX < $1.box.minX }) }
    }

    /// Group nearby OCR lines before translation so a paragraph is one request.
    /// Keep the union of its line boxes for the PiP's in-place overlay.
    static func mergeParagraphs(_ lines: [TextBlock]) -> [TextBlock] {
        guard var current = lines.first else { return [] }
        var result: [TextBlock] = []
        var lastLine = current
        var lineCount = 1
        for line in lines.dropFirst() {
            let gap = lastLine.box.minY - line.box.maxY
            let overlap = max(0, min(lastLine.box.maxX, line.box.maxX)
                              - max(lastLine.box.minX, line.box.minX))
            let shorterWidth = max(0.001, min(lastLine.box.width, line.box.width))
            let aligned = abs(lastLine.box.minX - line.box.minX) < 0.045
            let nearby = gap > -0.005 && gap < max(lastLine.box.height, line.box.height) * 0.9
            // Short groups (max 4 lines): measured on device, a long paragraph took
            // ~1 s per request, so short units let text appear progressively.
            if lineCount < 4 && aligned && nearby && overlap / shorterWidth > 0.55
                && current.original.count + line.original.count < 300 {
                current.original += "\n" + line.original
                current.box = current.box.union(line.box)
                lastLine = line
                lineCount += 1
            } else {
                result.append(current)
                current = line
                lastLine = line
                lineCount = 1
            }
        }
        result.append(current)
        return result
    }

    /// A system PiP can be present in ReplayKit's captured picture. When it
    /// repeats page text at a smaller scale, keep only the original text block.
    static func removeSmallerDuplicates(_ lines: [TextBlock]) -> [TextBlock] {
        func key(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        var largest: [String: CGFloat] = [:]
        let keys = lines.map { key($0.original) }
        for (line, text) in zip(lines, keys) where text.count >= 3 {
            largest[text] = max(largest[text] ?? 0, line.box.width * line.box.height)
        }
        return zip(lines, keys).compactMap { line, text in
            guard text.count >= 3 else { return line }
            return (largest[text] ?? 0) > line.box.width * line.box.height * 2.2 ? nil : line
        }
    }
}

@MainActor final class LocalTranslator {
    private var cache: [String: String] = [:]
    private var sessions: [String: TranslationSession] = [:]
    private var availability: [String: LanguageAvailability.Status] = [:]
    /// Optional fast offline engine installed by the app target (ML Kit).
    /// Returns translations in input order, or nil to use Apple Translation.
    static var fastEngine: (@MainActor ([String], String, String) async -> [String]?)?
    static let laneCount = 1  // 3 lanes measured: no gain, translationd serializes

    private func store(_ key: String, _ value: String) {
        if cache.count >= 800, let oldest = cache.keys.first { cache.removeValue(forKey: oldest) }
        cache[key] = value
    }

    func status(for source: String, target: AppLanguage) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                            to: Locale.Language(identifier: target.code ?? "zh-Hans"))
    }

    func translate(_ text: String, source preferred: AppLanguage,
                   target selectedTarget: AppLanguage = .simplifiedChinese) async throws -> String {
        if !text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { return text }
        let source = normalized(preferred.code ?? detectedSource(for: text))
        guard let targetCode = selectedTarget.code else { return text }
        if source == targetCode { return text }
        #if targetEnvironment(simulator)
        throw TranslationFailure.simulatorUnsupported
        #else
        let pair = "\(source)|\(targetCode)"
        let key = "\(pair)|\(text)"
        if let cached = cache[key] { return cached }
        // Voice captions and single-line lens edits use the same fast offline
        // engine as screen translation when it is selected and ready.
        if let engine = Self.fastEngine,
           let output = await engine([text], source, targetCode)?.first, !output.isEmpty {
            try Task.checkCancellation()
            store(key, output)
            return output
        }
        let session = try await session(for: source, target: selectedTarget)
        let output: String
        do {
            try Task.checkCancellation()
            output = try await session.translate(text).targetText
            try Task.checkCancellation()
        } catch {
            sessions.removeValue(forKey: "\(pair)#0")
            throw error
        }
        if cache.count >= 800, let oldest = cache.keys.first { cache.removeValue(forKey: oldest) }
        cache[key] = output
        return output
        #endif
    }

    func translateBatch(_ texts: [String], source preferred: AppLanguage,
                        target selectedTarget: AppLanguage = .simplifiedChinese,
                        receive: @escaping @MainActor (Int, String) -> Void,
                        progress: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        #if targetEnvironment(simulator)
        throw TranslationFailure.simulatorUnsupported
        #else
        guard let targetCode = selectedTarget.code else { return }
        let contextLanguage = detectedSource(for: texts.joined(separator: "\n"))
        var grouped: [String: [TranslationSession.Request]] = [:]
        var pendingKeys = Set<String>()
        var duplicateIndices: [String: [Int]] = [:]
        for (index, text) in texts.enumerated() {
            try Task.checkCancellation()
            if !text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
                receive(index, text)
                continue
            }
            // Detect only once per OCR line; the zh branch also skips
            // already-Chinese text instead of sending it to Translation.
            let language = normalized(preferred.code ?? sourceForLine(text, context: contextLanguage))
            if language == targetCode {
                receive(index, text)
                continue
            }
            // With a fixed source language (e.g. English), text that is plainly
            // already in the target script (Chinese UI, Japanese kana, Hangul)
            // must not be fed to the source model: it returns garbage slowly.
            let script = normalized(sourceForLine(text, context: contextLanguage))
            if preferred.code != nil, ["zh-Hans", "ja", "ko"].contains(script), script == targetCode {
                receive(index, text)
                continue
            }
            let key = "\(language)|\(targetCode)|\(text)"
            if let cached = cache[key] {
                receive(index, cached)
            } else if !pendingKeys.insert(key).inserted {
                // One model request can fill every identical OCR line on this page.
                duplicateIndices[key, default: []].append(index)
            } else {
                grouped[language, default: []].append(
                    TranslationSession.Request(sourceText: text, clientIdentifier: String(index)))
            }
        }
        var firstError: Error?
        progress("待翻译分组 " + grouped.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ","))
        for language in grouped.keys.sorted() {
            try Task.checkCancellation()
            guard let requests = grouped[language] else { continue }
            if let engine = Self.fastEngine {
                let indices = requests.compactMap { $0.clientIdentifier.flatMap(Int.init) }
                let started = Date()
                if indices.count == requests.count,
                   let outputs = await engine(indices.map { texts[$0] }, language, targetCode),
                   outputs.count == indices.count {
                    try Task.checkCancellation()
                    for (index, translated) in zip(indices, outputs) {
                        let key = "\(language)|\(targetCode)|\(texts[index])"
                        store(key, translated)
                        receive(index, translated)
                        for duplicate in duplicateIndices[key] ?? [] { receive(duplicate, translated) }
                    }
                    progress("合并翻译(离线快速引擎) \(indices.count) 段 用时 \(Int(Date().timeIntervalSince(started) * 1000))ms")
                    continue
                }
            }
            // Measured on device: every request costs ~1.3 s regardless of length,
            // and requests are processed one after another even across sessions
            // (12 blocks = 12 s). Send the whole page as ONE request, one block per
            // line, and split the answer by line. If the line count does not match,
            // fall back to per-block requests below so nothing is lost.
            // Merged requests in groups of 4 blocks, shown group by group: the
            // first group appears in ~2 s instead of waiting for the whole page.
            var leftovers: [TranslationSession.Request] = []
            var groupStart = 0
            while groupStart < requests.count {
                try Task.checkCancellation()
                let group = Array(requests[groupStart..<min(groupStart + 4, requests.count)])
                groupStart += 4
                let indices = group.compactMap { $0.clientIdentifier.flatMap(Int.init) }
                let joiner = ["zh", "zh-Hans", "ja", "ko", "th"].contains(language) ? "" : " "
                let lines = indices.map { index in
                    texts[index].replacingOccurrences(of: "\n", with: joiner)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard group.count >= 2, indices.count == group.count,
                      !lines.contains(where: \.isEmpty) else {
                    leftovers.append(contentsOf: group)
                    continue
                }
                do {
                    let started = Date()
                    let session = try await session(for: language, target: selectedTarget, lane: 0)
                    let output = try await session.translate(lines.joined(separator: "\n")).targetText
                    try Task.checkCancellation()
                    let parts = output.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    if parts.count == indices.count {
                        for (index, translated) in zip(indices, parts) {
                            let key = "\(language)|\(targetCode)|\(texts[index])"
                            store(key, translated)
                            receive(index, translated)
                            for duplicate in duplicateIndices[key] ?? [] { receive(duplicate, translated) }
                        }
                        progress("合并翻译 \(indices.count) 段 \(lines.reduce(0) { $0 + $1.count }) 字 用时 \(elapsed)ms")
                    } else {
                        progress("合并翻译行数不符 \(parts.count)/\(indices.count) 用时 \(elapsed)ms，改为逐段")
                        leftovers.append(contentsOf: group)
                    }
                } catch {
                    sessions.removeValue(forKey: "\(language)|\(targetCode)#0")
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    progress("合并翻译失败，改为逐段: \(error.localizedDescription)")
                    leftovers.append(contentsOf: group)
                }
            }
            guard !leftovers.isEmpty else { continue }
            let fallbackRequests = leftovers
            // Apple Translation answers one request at a time per session
            // (measured on device: 0.3-1.2 s per paragraph, serial). Spread the
            // page over a fixed pool of up to 3 sessions so they run in parallel.
            // Sessions are created once per language pair and reused; they are
            // never created per scroll (that flood crashed translationd).
            let lanes = min(Self.laneCount, fallbackRequests.count)
            var chunks = Array(repeating: [TranslationSession.Request](), count: lanes)
            for (offset, request) in fallbackRequests.enumerated() { chunks[offset % lanes].append(request) }
            var laneSessions: [TranslationSession] = []
            do {
                progress("检查语言包 \(language)")
                for lane in 0..<lanes {
                    laneSessions.append(try await session(for: language, target: selectedTarget, lane: lane))
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                progress("翻译错误 \(language): \(error.localizedDescription)")
                if firstError == nil { firstError = error }
                continue
            }
            progress("模型就绪 \(language)，等待首条译文")
            let duplicates = duplicateIndices
            let failures = await withTaskGroup(of: (Int, Error?).self) { group -> [(Int, Error)] in
                for lane in 0..<lanes {
                    let laneSession = laneSessions[lane]
                    let chunk = chunks[lane]
                    group.addTask { @MainActor in
                        do {
                            for try await response in laneSession.translate(batch: chunk) {
                                try Task.checkCancellation()
                                guard let index = response.clientIdentifier.flatMap(Int.init),
                                      texts.indices.contains(index) else { continue }
                                let key = "\(language)|\(targetCode)|\(texts[index])"
                                self.store(key, response.targetText)
                                receive(index, response.targetText)
                                for duplicate in duplicates[key] ?? [] {
                                    receive(duplicate, response.targetText)
                                }
                            }
                            return (lane, nil)
                        } catch {
                            return (lane, error)
                        }
                    }
                }
                var failed: [(Int, Error)] = []
                for await (lane, error) in group {
                    if let error { failed.append((lane, error)) }
                }
                return failed
            }
            for (lane, _) in failures {
                sessions.removeValue(forKey: "\(language)|\(targetCode)#\(lane)")
            }
            if Task.isCancelled { throw CancellationError() }
            if let error = failures.first?.1, !(error is CancellationError) {
                progress("翻译错误 \(language): \(error.localizedDescription)")
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        #endif
    }

    /// Create the session ahead of the first OCR result so the first page does not
    /// also pay for availability checks and model loading.
    func prewarm(source: String, target: AppLanguage) async {
        #if !targetEnvironment(simulator)
        guard let code = target.code, normalized(source) != code else { return }
        let state = await status(for: normalized(source), target: target)
        guard state == .installed else { return }
        // A separate session: loading the model is system-wide, and a session
        // shared with a running batch must never be used concurrently.
        let session = TranslationSession(installedSource: Locale.Language(identifier: normalized(source)),
                                         target: Locale.Language(identifier: code))
        _ = try? await session.translate("Hello")
        #endif
    }

    func resetSessions() { sessions.removeAll(); availability.removeAll() }

    private func session(for source: String, target: AppLanguage, lane: Int = 0) async throws -> TranslationSession {
        guard let targetCode = target.code else { throw TranslationFailure.unsupported }
        let pair = "\(source)|\(targetCode)"
        let key = "\(pair)#\(lane)"
        if let existing = sessions[key] { return existing }
        // Availability is checked once per pair: each check hits the system
        // asset store (the console filled with UAFAssetSet messages).
        let state: LanguageAvailability.Status
        if let known = availability[pair], known == .installed {
            state = known
        } else {
            state = await status(for: source, target: target)
            availability[pair] = state
        }
        guard state != .unsupported else { throw TranslationFailure.unsupported }
        guard state == .installed else { throw TranslationFailure.modelRequired(source, targetCode) }
        let created = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: targetCode))
        if sessions.count >= Self.laneCount * 3 { sessions.removeAll() }
        sessions[key] = created
        return created
    }

    private func normalized(_ code: String) -> String {
        code == "zh" || code.hasPrefix("zh-") ? "zh-Hans" : code
    }

    private static let supportedCodes = ["en", "ja", "ko", "zh", "fr", "de", "es", "it", "pt", "ru", "ar", "th", "vi", "id"]
    private static let latinCodes = ["en", "fr", "de", "es", "it", "pt", "vi", "id"]

    /// Language guess limited to the languages the app supports. Unrestricted
    /// guesses ("zh-Hant", "nb", "und"…) used to send whole groups of lines to
    /// a pair Apple Translation rejects (「这组语言暂不受苹果本机翻译支持」).
    private func recognize(_ text: String, among codes: [String]) -> String? {
        let detector = NLLanguageRecognizer()
        detector.languageConstraints = codes.map { NLLanguage(rawValue: $0 == "zh" ? "zh-Hans" : $0) }
        detector.processString(text)
        guard let raw = detector.dominantLanguage?.rawValue else { return nil }
        return raw.hasPrefix("zh") ? "zh" : raw
    }

    // Short labels and brand names are unreliable language samples. Reuse the
    // page language for these, while preserving explicit script differences.
    private func sourceForLine(_ text: String, context: String) -> String {
        let scalars = text.unicodeScalars.map(\.value)
        if scalars.contains(where: { (0x3040...0x30FF).contains($0) }) { return "ja" }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0) }) { return "ko" }
        if scalars.contains(where: { (0x3400...0x9FFF).contains($0) }) {
            return context == "ja" ? "ja" : "zh"
        }
        let latin = scalars.contains { (0x41...0x7A).contains($0) || (0xC0...0x24F).contains($0) }
        let contextIsCJK = ["zh", "zh-Hans", "ja", "ko"].contains(context)
        if latin && contextIsCJK {
            // A Latin-script line on a page that also shows Chinese/Japanese
            // (e.g. a screenshot with translations on it) is not CJK; before,
            // it inherited "zh" and was skipped as already translated.
            return text.count >= 12 ? (recognize(text, among: Self.latinCodes) ?? "en") : "en"
        }
        if text.count < 45, !contextIsCJK { return context }
        return detectedSource(for: text)
    }

    private func detectedSource(for text: String) -> String {
        let values = text.unicodeScalars.map(\.value)
        if values.contains(where: { (0xAC00...0xD7AF).contains($0) || (0x1100...0x11FF).contains($0) }) {
            // Mixed pages: only call the page Korean when it is mostly Korean.
            if let guess = recognize(text, among: Self.supportedCodes) { return normalized(guess) }
            return "ko"
        }
        if let guess = recognize(text, among: Self.supportedCodes) {
            return normalized(guess)
        }
        if values.contains(where: { (0x3040...0x30FF).contains($0) }) { return "ja" }
        if values.contains(where: { (0x3400...0x9FFF).contains($0) }) { return "zh-Hans" }
        return "en"
    }
}

enum TranslationFailure: LocalizedError {
    case modelRequired(String, String)
    case unsupported
    case simulatorUnsupported
    var errorDescription: String? {
        switch self {
        case .modelRequired(let source, let target): "请先在语言包管理中下载 \(source) → \(target)。"
        case .unsupported: "这组语言暂不受苹果本机翻译支持。"
        case .simulatorUnsupported: "苹果 Translation 不支持 iOS 模拟器，请在真机上翻译。"
        }
    }
}

/// Coarse grayscale fingerprint of a captured frame. It never leaves memory and is
/// used only to skip OCR when the screen has not changed since the last OCR pass.
enum FrameSignature {
    static let columns = 24
    static let rows = 40

    static func make(_ image: UIImage) -> [UInt8] { grid(image, columns: columns, rows: rows) }

    /// Area-averaged grayscale grid. A single CoreGraphics downscale by 60x
    /// samples only a few source pixels per cell, so the same page captured at
    /// two sizes (1800 px OCR frame vs 780 px preview) gave unrelated values.
    /// Draw to 8x4 sub-cells first and box-average them.
    static func grid(_ image: UIImage, columns: Int, rows: Int) -> [UInt8] {
        guard let cg = image.cgImage else { return [] }
        let sx = 8, sy = 4
        let width = columns * sx, height = rows * sy
        var fine = [UInt8](repeating: 0, count: width * height)
        let ok = fine.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return [] }
        var pixels = [UInt8](repeating: 0, count: columns * rows)
        fine.withUnsafeBufferPointer { source in
            for row in 0..<rows {
                for column in 0..<columns {
                    var total = 0
                    for y in (row * sy)..<(row * sy + sy) {
                        let base = y * width + column * sx
                        for x in 0..<sx { total += Int(source[base + x]) }
                    }
                    pixels[row * columns + column] = UInt8(total / (sx * sy))
                }
            }
        }
        return pixels
    }

    /// True only when no cell moved by more than a small tolerance (JPEG noise).
    static func isSame(_ a: [UInt8], _ b: [UInt8], excluding mask: CGRect? = nil) -> Bool {
        guard a.count == b.count, a.count == columns * rows else { return false }
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > 8 {
            if let mask {
                // Grid rows run bottom-up (CoreGraphics); mask is top-left based.
                let x = (CGFloat(index % columns) + 0.5) / CGFloat(columns)
                let y = 1 - (CGFloat(index / columns) + 0.5) / CGFloat(rows)
                if mask.insetBy(dx: -0.02, dy: -0.02).contains(CGPoint(x: x, y: y)) { continue }
            }
            return false
        }
        return true
    }
}

/// Estimates how far page content scrolled between the OCR frame and a newer
/// preview frame, so existing translations can move with the text instead of
/// staying at stale coordinates. Pure pixel statistics; nothing is stored.
struct ScrollEstimate {
    /// Content movement as a fraction of frame height; positive = moved up.
    /// nil means the page changed in a way that is not a plain vertical scroll.
    var shift: CGFloat?
    var topStable: Bool
    var bottomStable: Bool
    static let still = ScrollEstimate(shift: 0, topStable: true, bottomStable: true)
}

enum ScrollProfile {
    static let columns = 12
    static let rows = 320
    static let bandTop: CGFloat = 0.10
    static let bandBottom: CGFloat = 0.88

    static func make(_ image: UIImage) -> [UInt8] {
        FrameSignature.grid(image, columns: columns, rows: rows)
    }

    static func estimate(from reference: [UInt8], to current: [UInt8]) -> ScrollEstimate {
        guard reference.count == columns * rows, current.count == reference.count else { return .still }
        let top = Int(CGFloat(rows) * bandTop)
        let bottom = Int(CGFloat(rows) * bandBottom)
        let maxShift = rows / 2
        var best = Int.max, bestShift = 0, zero = Int.max
        func meanDiff(_ r: UnsafeBufferPointer<UInt8>, _ c: UnsafeBufferPointer<UInt8>,
                      _ from: Int, _ to: Int, _ shift: Int) -> Int {
            var total = 0
            for y in from..<to {
                let ro = y * columns, co = (y - shift) * columns
                for x in 0..<columns { total += abs(Int(r[ro + x]) - Int(c[co + x])) }
            }
            return total * 16 / max(1, (to - from) * columns)
        }
        var topScore = 0, bottomScore = 0
        reference.withUnsafeBufferPointer { r in
            current.withUnsafeBufferPointer { c in
                for shift in -maxShift...maxShift {
                    // Content at reference row y appears at current row y - shift.
                    let start = max(top, top + shift), end = min(bottom, bottom + shift)
                    guard end - start >= (bottom - top) / 3 else { continue }
                    let score = meanDiff(r, c, start, end, shift)
                    if shift == 0 { zero = score }
                    if score < best || (score == best && abs(shift) < abs(bestShift)) {
                        best = score
                        bestShift = shift
                    }
                }
                topScore = meanDiff(r, c, 0, top, 0)
                bottomScore = meanDiff(r, c, bottom, rows, 0)
            }
        }
        let topStable = topScore < 6 * 16
        let bottomStable = bottomScore < 6 * 16
        if best > 12 * 16 { return ScrollEstimate(shift: nil, topStable: topStable, bottomStable: bottomStable) }
        if bestShift != 0 && zero - best < 16 { bestShift = 0 }
        return ScrollEstimate(shift: CGFloat(bestShift) / CGFloat(rows),
                              topStable: topStable, bottomStable: bottomStable)
    }
}
