import SwiftUI
import PhotosUI
import Photos
import VisionKit
import AppIntents
import UniformTypeIdentifiers

struct OCRTextRange {
    let index: Int
    let start: Int
    let length: Int
    let box: CGRect
    var key: String { LensPartialTranslation.key(for: box) }
}

struct LensPartialTranslation {
    let box: CGRect
    let text: String
    static func key(for box: CGRect) -> String {
        String(format: "selected:%.4f:%.4f:%.4f:%.4f",
               box.minX, box.minY, box.width, box.height)
    }
}

struct LensSelectionSegment {
    let text: String
    let box: CGRect
}

@MainActor final class LensModel: ObservableObject {
    @Published var image: UIImage?
    @Published var translatedImage: UIImage?
    @Published var selectedTranslationImage: UIImage?
    @Published var selectedBusy = false
    @Published var blocks: [TextBlock] = []
    @Published var partialTranslations: [String: LensPartialTranslation] = [:]
    @Published var busy = false
    @Published var message = "导入图片后开始识别"
    @Published var source: AppLanguage = .auto
    @Published var target: AppLanguage = .simplifiedChinese
    let translator = LocalTranslator()
    private var generation = 0
    private var pipelineTask: Task<Void, Never>?
    private var recognizedBlocks: [TextBlock] = []

    func load(_ image: UIImage) {
        let startedAt = Date()
        pipelineTask?.cancel()
        self.image = image
        translatedImage = nil
        selectedTranslationImage = nil
        selectedBusy = false
        partialTranslations = [:]
        recognizedBlocks = []
        generation += 1
        let current = generation
        blocks = []
        busy = true
        message = "正在识别文字…"
        pipelineTask = Task {
            defer { if current == generation { pipelineTask = nil } }
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    try RecognitionService.recognize(image)
                }.value
                guard current == generation, !Task.isCancelled else { return }
                recognizedBlocks = found
                await translateRecognized(found, current: current, startedAt: startedAt,
                                          ocrMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000))
            } catch {
                if current == generation, !Task.isCancelled {
                    busy = false
                    message = "识别失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func retranslate(preserveSelected: Bool = false) {
        guard let image else { return }
        // The selected language can change while Vision is still recognizing.
        // In that case the current OCR pass will use the new language on completion.
        guard !recognizedBlocks.isEmpty else {
            if !busy { load(image) }
            return
        }
        pipelineTask?.cancel()
        generation += 1
        let current = generation
        translatedImage = nil
        selectedBusy = false
        if !preserveSelected {
            selectedTranslationImage = nil
            partialTranslations = [:]
        }
        blocks = recognizedBlocks
        busy = true
        let startedAt = Date()
        pipelineTask = Task {
            defer { if current == generation { pipelineTask = nil } }
            await translateRecognized(recognizedBlocks, current: current, startedAt: startedAt,
                                      ocrMilliseconds: 0)
        }
    }

    private func translateRecognized(_ found: [TextBlock], current: Int,
                                     startedAt: Date, ocrMilliseconds: Int) async {
        guard current == generation, !Task.isCancelled else { return }
        blocks = found
        guard !found.isEmpty else {
            busy = false
            message = "没有识别到文字"
            return
        }
        let selectedSource = source
        let selectedTarget = target
        message = "\(selectedSource.rawValue) → \(selectedTarget.rawValue)：正在翻译 \(found.count) 个文字区域…"
        var translatedCount = 0
        var firstTranslationMilliseconds: Int?
        var firstError: String?
        var pendingUpdates: [Int: String] = [:]
        var flushTask: Task<Void, Never>?
        var usedFast = false
        var usedApple = false
        func flushUpdates() {
            guard current == generation, !Task.isCancelled, !pendingUpdates.isEmpty else { return }
            var updated = blocks
            for (index, value) in pendingUpdates where updated.indices.contains(index) {
                updated[index].translated = value
            }
            pendingUpdates.removeAll(keepingCapacity: true)
            blocks = updated
        }
        do {
            try await translator.translateBatch(found.map(\.original), source: selectedSource, target: selectedTarget,
                                                receive: { index, value in
                guard current == self.generation, !Task.isCancelled,
                      self.blocks.indices.contains(index) else { return }
                pendingUpdates[index] = value
                if flushTask == nil {
                    flushTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        if !Task.isCancelled { flushUpdates() }
                        flushTask = nil
                    }
                }
                if value != found[index].original {
                    translatedCount += 1
                    if firstTranslationMilliseconds == nil {
                        firstTranslationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    }
                    self.message = "正在翻译 \(translatedCount)/\(found.count)"
                }
            }, progress: { stage in
                if stage.contains("离线快速引擎") { usedFast = true }
                else if stage.hasPrefix("合并翻译") { usedApple = true }
            })
        } catch {
            firstError = error.localizedDescription
        }
        flushTask?.cancel()
        flushTask = nil
        flushUpdates()
        guard current == generation, !Task.isCancelled else { return }
        let translationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        translatedImage = renderTranslatedImage()
        busy = false
        recordTiming(imagePixels: image.map { Int($0.size.width * $0.size.height) } ?? 0,
                     recognizedCount: found.count, translatedCount: translatedCount,
                     ocrMilliseconds: ocrMilliseconds,
                     firstTranslationMilliseconds: firstTranslationMilliseconds,
                     translationMilliseconds: translationMilliseconds,
                     finalMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000))
        if let firstError { message = firstError }
        else {
            // Say which engine did the work, so it is clear that the fast
            // offline engine was used (or why Apple Translation was).
            let engine = usedFast && !usedApple ? " · 离线快速引擎"
                : usedFast ? " · 部分语言用了苹果翻译（离线模型未下载）"
                : usedApple ? (MLKitEngine.preferFast ? " · 苹果翻译（该语言离线模型未下载）" : " · 苹果翻译") : ""
            qyLog("lens translated \(translatedCount)/\(found.count) fast=\(usedFast) apple=\(usedApple)")
            message = translatedCount > 0
                ? "\(selectedSource.rawValue) → \(selectedTarget.rawValue)：翻译完成\(engine)"
                : "识别完成，没有需要翻译的文字"
        }
    }

    private func recordTiming(imagePixels: Int, recognizedCount: Int, translatedCount: Int,
                              ocrMilliseconds: Int, firstTranslationMilliseconds: Int?,
                              translationMilliseconds: Int, finalMilliseconds: Int) {
        let report = """
        time=\(ISO8601DateFormatter().string(from: Date()))
        imagePixels=\(imagePixels)
        recognizedBlocks=\(recognizedCount)
        translatedBlocks=\(translatedCount)
        ocrMs=\(ocrMilliseconds)
        firstTranslationMs=\(firstTranslationMilliseconds.map(String.init) ?? "none")
        batchTranslationMs=\(translationMilliseconds)
        finalImageMs=\(finalMilliseconds)
        """
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? report.write(to: documents.appendingPathComponent("lens-timing.txt"), atomically: true, encoding: .utf8)
    }

    func allText(translated: Bool) -> String {
        blocks.map { translated && !$0.translated.isEmpty ? $0.translated : $0.original }.joined(separator: "\n")
    }

    func translateSelected(segments: [LensSelectionSegment]) async {
        let segments = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.box.width > 0 && $0.box.height > 0
        }
        guard !segments.isEmpty else { return }
        pipelineTask?.cancel()
        pipelineTask = nil
        generation += 1
        let current = generation
        selectedTranslationImage = nil
        selectedBusy = true
        busy = false
        message = "正在翻译选中文字…"
        do {
            try await translator.translateBatch(segments.map(\.text), source: source, target: target, receive: { index, value in
                guard current == self.generation, !Task.isCancelled,
                      segments.indices.contains(index) else { return }
                let segment = segments[index]
                let key = LensPartialTranslation.key(for: segment.box)
                self.partialTranslations[key] = LensPartialTranslation(box: segment.box, text: value)
            })
            if current == generation, !Task.isCancelled {
                selectedTranslationImage = renderTranslatedImage(
                    includeAutomatic: false, includeSelected: true)
                selectedBusy = false
                message = "选中文字已在原位翻译"
            }
        } catch {
            if current == generation, !Task.isCancelled {
                selectedTranslationImage = renderTranslatedImage(
                    includeAutomatic: false, includeSelected: true)
                selectedBusy = false
                message = "选中翻译失败：\(error.localizedDescription)"
            }
        }
    }

    func renderTranslatedImage(includeAutomatic: Bool = true,
                               includeSelected: Bool = false) -> UIImage? {
        guard let image else { return nil }
        func fittedFont(for text: String, in rect: CGRect) -> UIFont {
            var size = max(14, min(96, rect.height * 0.82))
            while size > 14 {
                let font = UIFont.systemFont(ofSize: size)
                let bounds = (text as NSString).boundingRect(
                    with: CGSize(width: max(1, rect.width), height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font], context: nil)
                if bounds.height <= rect.height * 1.1 { return font }
                size = max(14, size * 0.84)
            }
            return .systemFont(ofSize: size)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            for block in blocks where includeAutomatic && !block.translated.isEmpty
                && block.translated != block.original {
                let rect = CGRect(x: block.box.minX * image.size.width,
                                  y: (1 - block.box.maxY) * image.size.height,
                                  width: block.box.width * image.size.width,
                                  height: block.box.height * image.size.height)
                let textRect = rect.insetBy(dx: -2, dy: -2)
                UIColor.systemBackground.withAlphaComponent(0.98).setFill()
                UIBezierPath(roundedRect: textRect, cornerRadius: 2).fill()
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                (block.translated as NSString).draw(in: rect, withAttributes: [
                    .font: fittedFont(for: block.translated, in: rect),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraph
                ])
            }
            for overlay in partialTranslations.values where includeSelected {
                let rect = CGRect(x: overlay.box.minX * image.size.width,
                                  y: (1 - overlay.box.maxY) * image.size.height,
                                  width: overlay.box.width * image.size.width,
                                  height: overlay.box.height * image.size.height)
                UIColor.systemBackground.withAlphaComponent(0.98).setFill()
                UIBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 2).fill()
                (overlay.text as NSString).draw(in: rect, withAttributes: [
                    .font: fittedFont(for: overlay.text, in: rect),
                    .foregroundColor: UIColor.label
                ])
            }
        }
        return rendered
    }
}

struct LensHome: View {
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @ObservedObject var model: LensModel
    @State private var picked: PhotosPickerItem?
    @State private var showingLens = false
    @State private var importGeneration = 0
    @State private var showShortcutHelp = false
    @State private var showLensHelp = false

    var body: some View {
        Group {
        if visualTheme == 5 { mistLayout } else if visualTheme == 4 { nativeThemeLayout } else if visualTheme == 3 { themeFourLayout } else if visualTheme == 2 { themeThreeLayout } else if visualTheme == 1 { warmLayout } else {
        ScrollView { VStack(spacing: 18) {
            Image(systemName: "viewfinder")
                .font(.system(size: 54, weight: .thin)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 170)
                .clearGlass(28)
            Text("智能镜头").font(.system(size: 27, weight: .light, design: .rounded))
            Text("识别截图中的文字，在原位置显示译文。支持选择、复制、搜索和保存。")
                .foregroundStyle(.white.opacity(0.90)).multilineTextAlignment(.center)
            PhotosPicker(selection: $picked, matching: .images) {
                Label("导入图片", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity).padding().clearGlass(30).foregroundStyle(.white)
            }
            Button("从剪贴板导入") {
                if let image = UIPasteboard.general.image { model.load(image); showingLens = true }
                else { model.message = "剪贴板里没有图片" }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            ShortcutGuide().padding(18).clearGlass(24)
            Text(model.message).font(.footnote).foregroundStyle(.white.opacity(0.90))
            Text("其他 App 的当前画面，请先截图并从这里导入。")
                .font(.caption).foregroundStyle(.white.opacity(0.90))
            Text("快捷指令可添加「截屏」→「用青译识别图片」，把截屏结果传给青译。主屏幕小组件可快速打开智能镜头。")
                .font(.caption).foregroundStyle(.white.opacity(0.90))
        }
        .padding()
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        } } }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            importGeneration += 1
            let current = importGeneration
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        if current == importGeneration { model.message = "无法读取图片，请重新选择"; picked = nil }
                        return
                    }
                    guard current == importGeneration else { return }
                    // Normalize camera-photo orientation for both Vision and the overlay.
                    let normalized: UIImage
                    if image.imageOrientation == .up {
                        normalized = image
                    } else {
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = image.scale
                        normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                            image.draw(in: CGRect(origin: .zero, size: image.size))
                        }
                    }
                    model.load(normalized)
                    picked = nil
                    // Let the system photo picker finish dismissing before presenting the lens.
                    try? await Task.sleep(for: .milliseconds(450))
                    guard current == importGeneration else { return }
                    showingLens = true
                } catch {
                    if current == importGeneration { model.message = "读取图片失败：\(error.localizedDescription)"; picked = nil }
                }
            }
        }
        .fullScreenCover(isPresented: $showingLens) { LensView(model: model, onClose: { showingLens = false }) }
        .sheet(isPresented: $showShortcutHelp) {
            MistHelpSheet(title: "用快捷指令截图翻译", lines: [
                "打开系统「快捷指令」，点右上角加号新建。",
                "添加「截屏」操作。",
                "添加「用青译识别图片」，图片选上一步的截屏。",
                "保存后可在系统设置里绑定到操作按钮或轻点背面，随时一键翻译屏幕。"])
        }
    }

    // MARK: 雾面

    private var openLastAction: (() -> Void)? {
        guard model.image != nil else { return nil }
        return { showingLens = true }
    }

    private var mistLayout: some View {
        let translated = model.blocks.filter { !$0.translated.isEmpty && $0.translated != $0.original }.count
        let progress: Double = model.image == nil ? 0.125 : (model.busy ? 0.375 : (translated > 0 ? 0.875 : 0.625))
        let insightTitle = model.image == nil ? "导入一张图片" : (model.busy ? "正在识别与翻译" : "译文已贴回原处")
        let insightDetail = model.image == nil
            ? "截图或照片都可以，译文会直接贴在原文的位置。"
            : (model.busy ? model.message : "点一下选一句，再点选整段；按住拖动可自由选择。")
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MistTopBar(title: "智能镜头") {
                    MistCircleButton(systemImage: "questionmark", label: "怎么选字") { showLensHelp = true }
                } right: {
                    MistCircleButton(systemImage: "bolt.horizontal.circle", label: "快捷指令") { showShortcutHelp = true }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("从这里导入").font(.system(size: 12, weight: .light)).italic()
                        .foregroundStyle(.white.opacity(0.88)).padding(.leading, 14)
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $picked, matching: .images) {
                            MistCapsuleLabel(systemImage: "photo", title: "相册")
                        }.buttonStyle(.plain)
                        Button {
                            if let image = UIPasteboard.general.image { model.load(image); showingLens = true }
                            else { model.message = "剪贴板里没有图片" }
                        } label: { MistCapsuleLabel(systemImage: "doc.on.clipboard", title: "剪贴板") }
                            .buttonStyle(.plain)
                        Button { showingLens = true } label: {
                            MistCapsuleLabel(systemImage: "clock.arrow.circlepath", title: "上一张")
                        }
                        .buttonStyle(.plain).disabled(model.image == nil).opacity(model.image == nil ? 0.5 : 1)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    MistCardHeader(title: "识图翻译", actionTitle: "打开", action: openLastAction)
                    HStack(alignment: .center) {
                        MistBigValue(value: "\(model.blocks.count)", suffix: "段文字")
                        Spacer(minLength: 8)
                        if let image = model.image {
                            Button { showingLens = true } label: {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 54, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Mist.ink.opacity(0.08)))
                            }.buttonStyle(.plain).accessibilityLabel("打开上一张图片")
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                MistStat(fraction: 0, text: model.target.rawValue)
                                MistStat(fraction: 0, text: "本机识别", dim: true)
                            }
                        }
                    }
                    MistArcGauge(labels: ["导入", "识别", "翻译", "选择"], progress: progress,
                                 active: model.busy, level: 0.6)
                        .equatable()
                        .padding(.horizontal, -22)
                    MistInsight(title: insightTitle, detail: insightDetail)
                    PhotosPicker(selection: $picked, matching: .images) {
                        MistPrimaryLabel(title: "导入图片", systemImage: "photo.on.rectangle")
                    }.buttonStyle(.plain)
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap").font(.system(size: 13, weight: .light))
                        Text("点一句选一句，再点选整段；按住拖动自由选择").font(Mist.light(12))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Mist.inkSoft).frame(maxWidth: .infinity)
                }
                .mistCard()
            }
            .padding(.horizontal, 18).padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $showLensHelp) {
            MistHelpSheet(title: "智能镜头怎么用", lines: [
                "从相册、剪贴板导入图片，或用快捷指令截屏后直接打开。",
                "译文会贴在原文的位置；右下角可切换原文和翻译。",
                "点一句选一句，再点一次选整段；点网址、数字只选它本身。",
                "按住拖动可以自由选择一段，开头没对准会自动补齐。",
                "右上角分享按钮直接分享译图，「⋯」里有更多操作。"])
        }
    }

    private var nativeThemeLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { VStack(alignment: .leading, spacing: 5) { Text("智能镜头").font(.largeTitle.bold()); Text("看懂图片里的每一句话").font(.subheadline).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "viewfinder").font(.title3).frame(width: 48, height: 48).background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle()) }.padding(.top, 8)
                VStack(alignment: .leading, spacing: 14) {
                    Text("识别与翻译").font(.title3.weight(.medium))
                    Text("选择图片，原文会在画面中对应的位置翻译。") .font(.subheadline).opacity(0.9)
                    Image(systemName: "text.viewfinder").font(.system(size: 60, weight: .ultraLight)).frame(maxWidth: .infinity).frame(height: 170)
                    PhotosPicker(selection: $picked, matching: .images) { Label("导入图片", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(15).foregroundStyle(.white).background(.black, in: Capsule()) }.buttonStyle(.plain)
                }.padding(22).foregroundStyle(.primary).nativeThemeCard()
                Button { if let image = UIPasteboard.general.image { model.load(image); showingLens = true } else { model.message = "剪贴板里没有图片" } } label: { HStack(spacing: 14) { Image(systemName: "doc.on.clipboard").font(.title3).frame(width: 44, height: 44).background(Color.primary.opacity(0.06), in: Circle()); VStack(alignment: .leading, spacing: 4) { Text("从剪贴板导入").font(.headline); Text("使用已复制的图片").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(18).contentShape(Rectangle()).nativeThemeCard() }.buttonStyle(.plain)
                ShortcutGuide().padding(18).nativeThemeCard()
                Text(model.message).font(.footnote).foregroundStyle(.secondary)
                Text("其他 App 的画面可先截图，再导入智能镜头。快捷指令也可将截图传给青译。") .font(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 30)
        }
    }
    private var themeFourLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text("随手识别，轻松看懂").font(.caption).foregroundStyle(.secondary); Text("智能镜头").font(.system(size: 27, weight: .bold)) }; Spacer(); Image(systemName: "viewfinder").frame(width: 50, height: 50).background(Color(red: 0.78, green: 0.71, blue: 0.91), in: Circle()).foregroundStyle(.black) }
                VStack(alignment: .leading, spacing: 14) {
                    HStack { VStack(alignment: .leading, spacing: 8) { Text("图片翻译").font(.title2.bold()); Text("保留原图，原位查看译文").font(.subheadline) }; Spacer(); Image(systemName: "text.viewfinder").font(.system(size: 50, weight: .light)).padding(18).background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 24)) }
                    PhotosPicker(selection: $picked, matching: .images) { Label("导入图片", systemImage: "photo.on.rectangle").padding(.horizontal, 20).padding(.vertical, 12).foregroundStyle(.white).background(.black, in: Capsule()) }.buttonStyle(.plain)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).foregroundStyle(.black).themeFourCard(Color(red: 0.86, green: 0.64, blue: 0.92))
                Text("快捷操作").font(.title3.bold())
                Button { if let image = UIPasteboard.general.image { model.load(image); showingLens = true } else { model.message = "剪贴板里没有图片" } } label: {
                    HStack(spacing: 16) { Image(systemName: "doc.on.clipboard").font(.title).frame(width: 72, height: 72).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 21)); VStack(alignment: .leading, spacing: 5) { Text("从剪贴板导入").font(.headline); Text("选择已复制的图片").font(.caption) }; Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.white).padding(12).background(.black, in: Circle()) }.padding(14).foregroundStyle(.black).themeFourCard(Color(red: 1, green: 0.92, blue: 0.58))
                }.buttonStyle(.plain)
                ShortcutGuide().padding(18).themeFourCard()
                Text(model.message).font(.footnote).foregroundStyle(.secondary)
                Text("其他 App 的画面可先截图，再导入智能镜头。") .font(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
    private var themeThreeLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { VStack(alignment: .leading, spacing: 5) { Text("智能镜头").font(.system(size: 28, weight: .medium, design: .rounded)); Text("看懂图片里的每一句话").font(.subheadline).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "viewfinder").font(.title3).frame(width: 48, height: 48).background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle()) }.padding(.top, 8)
                VStack(alignment: .leading, spacing: 14) {
                    Text("识别与翻译").font(.title3.weight(.medium))
                    Text("选择图片，原文会在画面中对应的位置翻译。") .font(.subheadline).opacity(0.9)
                    Image(systemName: "text.viewfinder").font(.system(size: 60, weight: .ultraLight)).frame(maxWidth: .infinity).frame(height: 170)
                    PhotosPicker(selection: $picked, matching: .images) { Label("导入图片", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(15).foregroundStyle(.white).background(.black, in: Capsule()) }.buttonStyle(.plain)
                }.padding(22).foregroundStyle(.white).themeThreeCard(true)
                Button { if let image = UIPasteboard.general.image { model.load(image); showingLens = true } else { model.message = "剪贴板里没有图片" } } label: { HStack(spacing: 14) { Image(systemName: "doc.on.clipboard").font(.title3).frame(width: 44, height: 44).background(Color.primary.opacity(0.06), in: Circle()); VStack(alignment: .leading, spacing: 4) { Text("从剪贴板导入").font(.headline); Text("使用已复制的图片").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(18).contentShape(Rectangle()).themeThreeCard() }.buttonStyle(.plain)
                ShortcutGuide().padding(18).themeThreeCard()
                Text(model.message).font(.footnote).foregroundStyle(.secondary)
                Text("其他 App 的画面可先截图，再导入智能镜头。快捷指令也可将截图传给青译。") .font(.footnote).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 30)
        }
    }
    private var warmLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "viewfinder").font(.title3).padding(12).clearGlass(25)
                    VStack(alignment: .leading, spacing: 3) { Text("智能镜头").font(.headline); Text("图片文字 · 原位翻译").font(.caption).opacity(0.8) }
                    Spacer()
                }.padding(18).clearGlass(28)
                VStack(alignment: .leading, spacing: 16) {
                    Text("识别并翻译").font(.title2.weight(.light))
                    Text("导入截图或图片，识别文字并在原位置显示译文。") .font(.subheadline).opacity(0.85)
                    Image(systemName: "text.viewfinder").font(.system(size: 56, weight: .ultraLight)).frame(maxWidth: .infinity).frame(height: 150)
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label("导入图片", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(15)
                            .background(Color(red: 1, green: 0.47, blue: 0.39).opacity(0.55), in: Capsule()).clearGlass(30)
                    }.buttonStyle(.plain)
                }.padding(20).clearGlass(28)
                Button {
                    if let image = UIPasteboard.general.image { model.load(image); showingLens = true }
                    else { model.message = "剪贴板里没有图片" }
                } label: { HStack { Image(systemName: "doc.on.clipboard").padding(12).clearGlass(24); VStack(alignment: .leading, spacing: 4) { Text("从剪贴板导入"); Text("使用已复制的图片").font(.caption).opacity(0.75) }; Spacer(); Image(systemName: "chevron.right") }.padding(14).clearGlass(24) }.buttonStyle(.plain)
                ShortcutGuide().padding(18).clearGlass(24)
                Text(model.message).font(.footnote).opacity(0.85)
                Text("其他 App 的画面可先截图，再导入智能镜头。") .font(.footnote).opacity(0.8)
            }.padding(.horizontal, 20).padding(.bottom, 24).foregroundStyle(.white)
        }
    }
}

private struct ShortcutGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("设置截图快捷指令", systemImage: "bolt.horizontal.circle").font(.headline)
            Text("1. 打开系统「快捷指令」，点击右上角加号新建。\n2. 添加「截屏」操作。\n3. 添加「用青译识别图片」，将图片参数设为上一步的截屏。\n4. 命名并保存；可在系统设置中将它绑定到操作按钮或轻点背面。")
                .font(.footnote).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum LensDisplayMode: String {
    case original, selected, full
}

struct LensView: View {
    @StateObject private var installedLanguages = InstalledLanguageOptions()
    @ObservedObject var model: LensModel
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lensSelectionMenuDraggable") private var menuDraggable = true
    @AppStorage("lensAutoFitSnap") private var autoFitSnap = true
    @AppStorage("lensDragSnapsSentences") private var dragSnapsSentences = false
    @AppStorage("lensZoomEnabled") private var zoomEnabled = true
    @State private var displayMode: LensDisplayMode = .full
    @State private var zoomResetToken = 0
    @State private var selectionMenuOffset = CGSize.zero
    @State private var menuDragBase: CGSize?
    @State private var menuAnchorOverride: CGPoint?
    @State private var menuSize = CGSize(width: 240, height: 34)
    @State private var showLanguagePacks = false
    @State private var saveMessage = ""
    @State private var selectedText = ""
    @State private var selectedTranslation = ""
    @State private var copyingTranslation = false
    @State private var selectedLink = ""
    @State private var selectedIndices: [Int] = []
    @State private var selectedRange: OCRTextRange?
    @State private var selectedBox: CGRect?
    @State private var selectedSegments: [LensSelectionSegment] = []
    @State private var selectionAnchor: CGPoint?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = visibleImage {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        LiveTextImageView(image: image, viewport: geometry.size,
                                          blocks: model.blocks,
                                          partialTranslations: model.partialTranslations,
                                          autoFitSnap: autoFitSnap,
                                          dragSnapsSentences: dragSnapsSentences,
                                          zoomEnabled: zoomEnabled,
                                          zoomResetToken: zoomResetToken,
                                          showProgressOverlay: displayMode == .full
                                              && model.busy && model.translatedImage == nil,
                                          showSelectedProgressOverlay: displayMode == .selected
                                              && model.selectedTranslationImage == nil,
                                          analysisEnabled: true,
                                          selectedText: $selectedText,
                                          selectedTranslation: $selectedTranslation,
                                          selectedLink: $selectedLink,
                                          selectedIndices: $selectedIndices,
                                          selectedRange: $selectedRange,
                                          selectedBox: $selectedBox,
                                          selectedSegments: $selectedSegments,
                                          selectionAnchor: $selectionAnchor)
                        if let anchor = selectionAnchor {
                            if !selectedText.isEmpty {
                                selectionMenu(anchor: anchor, area: geometry.size)
                                    .highPriorityGesture(menuDrag(anchor: anchor, area: geometry.size, minimum: 6),
                                                         including: menuDraggable ? .all : .none)
                                    .position(menuPosition(menuAnchorOverride ?? anchor, in: geometry.size,
                                                           offset: selectionMenuOffset))
                            }
                        }
                    }
                }
                    .ignoresSafeArea()
            }
            VStack {
                // Three plain glass controls with full 44-pt hit areas: close,
                // one language capsule, share (tap) and ⋯ (all other tools).
                // The old text buttons only reacted on their label text, so
                // taps on the glass around "关闭" were sometimes ignored.
                HStack(spacing: 10) {
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("关闭")
                    Spacer(minLength: 0)
                    languageBar
                    Spacer(minLength: 0)
                    Button { shareVisibleImage() } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .offset(y: -1)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("分享译图")
                    moreMenu
                }
                .foregroundStyle(.primary)
                 .padding(.horizontal, 12)
                 // Sits right under the Dynamic Island. The cover's own safe
                 // area is not reliable: presented while the photo picker is
                 // still closing it can be zero, which pushed the bar under the
                 // status bar where it could not be tapped. Use the window's
                 // inset instead, with the container's safe area ignored.
                 .padding(.top, windowInsets.top + 2)
                Spacer()
                HStack {
                    if model.busy || model.selectedBusy || !saveMessage.isEmpty
                        || model.message.contains("失败") || model.message.hasPrefix("请先")
                        || model.message.contains("不受苹果") || model.message.contains("苹果翻译") {
                        Text(saveMessage.isEmpty ? model.message : saveMessage)
                            .font(.caption).padding(9).background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    Button {
                        if displayMode == .full {
                            clearSelection()
                            displayMode = .original
                        } else {
                            showFullTranslation()
                        }
                    } label: {
                        Label(displayMode == .full ? "原文" : "翻译", systemImage: "translate")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(height: 40)
                            .contentShape(Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18).padding(.bottom, windowInsets.bottom + 118)
            }
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .foregroundStyle(.primary)
        .statusBarHidden(false)
        .onChange(of: selectedText) { _, _ in
            if menuDragBase == nil {
                selectionMenuOffset = .zero
                menuAnchorOverride = nil
            }
        }
        .task(id: "\(model.source.rawValue)|\(model.target.rawValue)") { await installedLanguages.refresh(source: model.source, target: model.target) }
        .onReceive(NotificationCenter.default.publisher(for: .init("QingyiLanguagePacksChanged"))) { _ in Task { await installedLanguages.refresh(source: model.source, target: model.target) } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await installedLanguages.refresh(source: model.source, target: model.target, speech: false) } }
        .onChange(of: model.source) { _, _ in displayMode = .full; model.retranslate() }
        .onReceive(NotificationCenter.default.publisher(for: .init("QingyiLanguagePacksChanged"))) { _ in displayMode = .full; model.retranslate() }
        .onChange(of: model.target) { _, _ in displayMode = .full; model.retranslate() }
        .sheet(isPresented: $showLanguagePacks) { NavigationStack { LanguagePackView(source: model.source, target: model.target) } }
    }

    private func close() {
        clearSelection()
        if let onClose { onClose() } else { dismiss() }
    }

    /// Two separate capsules so it is clear which one is tapped:
    /// 「原文 英语」 → 「译成 简体中文」.
    private var languageBar: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("原文语言", selection: $model.source) {
                    ForEach(installedLanguages.sourceOptions(current: model.source, auto: true)) { Text(installedLanguages.sourceLabel($0)).tag($0).disabled($0 != .auto && !installedLanguages.sources.contains($0)) }
                }
            } label: {
                languageCapsuleLabel(title: "原文", value: model.source.rawValue)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel("原文语言，当前\(model.source.rawValue)")
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
            Menu {
                ForEach(installedLanguages.targetOptions(current: model.target)) { language in
                    Button {
                        model.target = language
                    } label: {
                        if language == model.target {
                            Label(language.rawValue, systemImage: "checkmark")
                        } else {
                            Text(language.rawValue)
                        }
                    }.disabled(!installedLanguages.targets.contains(language))
                }
                Divider()
                Button("检查或下载语言包", systemImage: "arrow.down.circle") { showLanguagePacks = true }
            } label: {
                languageCapsuleLabel(title: "译成", value: model.target.rawValue)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel("译成，当前\(model.target.rawValue)")
        }
    }

    private func languageCapsuleLabel(title: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 64)
        .frame(height: 44)
        .contentShape(Capsule())
    }

    private var moreMenu: some View {
        Menu {
            Section("分享") {
                Button("分享整张译图", systemImage: "photo") { shareVisibleImage() }
                Button("分享已选译文图片", systemImage: "photo.on.rectangle.angled") { shareSelectedTranslationImage() }
                    .disabled(model.partialTranslations.isEmpty)
                Button("分享选中文字的译文", systemImage: "text.quote") { shareSelection() }
                    .disabled(selectedText.isEmpty)
                Button("分享全部译文文字", systemImage: "doc.plaintext") { shareTranslatedText() }
            }
            Section("显示") {
                Button("显示原图", systemImage: "photo") { clearSelection(); displayMode = .original }
                Button("显示已选译文", systemImage: "checkmark.rectangle") { clearSelection(); displayMode = .selected }
                    .disabled(model.partialTranslations.isEmpty)
                Button("还原全图大小", systemImage: "arrow.down.right.and.arrow.up.left") { zoomResetToken += 1 }
                Button("重新识别并翻译", systemImage: "arrow.clockwise") { displayMode = .full; model.retranslate() }
            }
            Section("复制与保存") {
                Button("复制全部原文", systemImage: "doc.on.doc") { copyText(model.allText(translated: false), note: "已复制全部原文", joinLines: false) }
                Button("复制全部译文", systemImage: "doc.on.doc.fill") { copyText(model.allText(translated: true), note: "已复制全部译文", joinLines: false) }
                    .disabled(!model.blocks.contains { !$0.translated.isEmpty && $0.translated != $0.original })
                Button("复制当前图片", systemImage: "photo.on.rectangle") { UIPasteboard.general.image = visibleImage }
                Button("保存译文图片", systemImage: "square.and.arrow.down") { saveImage() }
            }
            Section("选字") {
                Picker("拖动选字", selection: $dragSnapsSentences) {
                    Text("自由拖动").tag(false)
                    Text("按整句吸附").tag(true)
                }
                Toggle("可拖动选字菜单", isOn: $menuDraggable)
            }
            Button("语言包", systemImage: "globe") { showLanguagePacks = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("更多")
    }

    private var windowInsets: UIEdgeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        let insets = window?.safeAreaInsets ?? .zero
        return UIEdgeInsets(top: max(insets.top, 20), left: insets.left,
                            bottom: insets.bottom, right: insets.right)
    }

    /// Shares the image currently on screen: the fully translated picture,
    /// or (in 已选译文 mode) the picture with only the user's chosen
    /// translations. Presented through UIKit from the top view controller so
    /// it works the same inside the in-app cover and the Shortcut cover.
    private func shareVisibleImage() {
        let image: UIImage?
        switch displayMode {
        case .selected: image = model.selectedTranslationImage ?? model.translatedImage ?? model.image
        case .original: image = model.translatedImage ?? model.image
        case .full: image = model.translatedImage ?? model.renderTranslatedImage() ?? model.image
        }
        guard let image else { saveMessage = "图片还没准备好"; return }
        presentShare([image])
    }

    private func shareSelectedTranslationImage() {
        guard !model.partialTranslations.isEmpty else { saveMessage = "还没有选中翻译的内容"; return }
        let image = model.selectedTranslationImage
            ?? model.renderTranslatedImage(includeAutomatic: false, includeSelected: true)
        guard let image else { return }
        presentShare([image])
    }

    private func shareTranslatedText() {
        let text = model.allText(translated: true)
        guard !text.isEmpty else { saveMessage = "译文尚未生成"; return }
        presentShare([text])
    }

    private func shareSelection() {
        let original = selectedText
        guard !original.isEmpty else { return }
        if !selectedLink.isEmpty { presentShare([selectedLink]); return }
        let source = model.source
        let target = model.target
        Task { @MainActor in
            var translated = selectedTranslation
            if translated.isEmpty || translated == original {
                translated = (try? await model.translator.translate(original, source: source, target: target)) ?? ""
            }
            presentShare([translated.isEmpty || translated == original ? original : "\(translated)\n\n原文：\(original)"])
        }
    }

    private func presentShare(_ items: [Any]) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.maxX - 40, y: windowInsets.top + 20, width: 1, height: 1)
        }
        top.present(controller, animated: true)
    }

    private var visibleImage: UIImage? {
        switch displayMode {
        case .original: model.image
        case .selected: model.selectedTranslationImage ?? model.image
        case .full: model.translatedImage ?? model.image
        }
    }

    private func showFullTranslation() {
        clearSelection()
        displayMode = .full
        if model.translatedImage == nil && !model.busy {
            model.retranslate(preserveSelected: true)
        }
    }

    private func selectionMenu(anchor: CGPoint, area: CGSize) -> some View {
        HStack(spacing: 12) {
            if menuDraggable {
                // Dedicated grip: a drag here never competes with the buttons.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 30)
                    .contentShape(Rectangle())
                    .gesture(menuDrag(anchor: anchor, area: area, minimum: 0))
                    .accessibilityLabel("拖动菜单")
            }
            if !selectedLink.isEmpty {
                Button("复制链接") { copyText(selectedLink, note: "已复制链接", joinLines: false) }
            } else {
                Button("复制原文") { copyText(selectedText, note: "已复制原文") }
                Button(copyingTranslation ? "正在复制…" : "复制译文") { copySelectedTranslation() }
                    .disabled(copyingTranslation || selectedText.isEmpty)
                Button("翻译选中") { translateSelection() }
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.leading, menuDraggable ? 4 : 10).padding(.trailing, 10).padding(.vertical, 3)
        .frame(minHeight: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.25), radius: 5, y: 1)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { menuSize = $0 }
    }

    /// Moves the copy menu. The offset is kept inside the visible area so a
    /// later drag never starts from a position the menu cannot reach.
    private func menuDrag(anchor: CGPoint, area: CGSize, minimum: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: minimum, coordinateSpace: .global)
            .onChanged { value in
                guard menuDraggable else { return }
                if menuDragBase == nil {
                    menuDragBase = selectionMenuOffset
                    menuAnchorOverride = menuAnchorOverride ?? anchor
                }
                let base = menuDragBase ?? .zero
                selectionMenuOffset = CGSize(width: base.width + value.translation.width,
                                             height: base.height + value.translation.height)
            }
            .onEnded { _ in
                let origin = menuAnchorOverride ?? anchor
                let free = menuPosition(origin, in: area, offset: .zero, clamp: false)
                let shown = menuPosition(origin, in: area, offset: selectionMenuOffset)
                selectionMenuOffset = CGSize(width: shown.x - free.x, height: shown.y - free.y)
                menuDragBase = nil
            }
    }

    private func menuPosition(_ anchor: CGPoint, in size: CGSize,
                              offset: CGSize, clamp: Bool = true) -> CGPoint {
        let preferredY = anchor.y > size.height * 0.65 ? anchor.y - 60 : anchor.y + 60
        let point = CGPoint(x: anchor.x + offset.width, y: preferredY + offset.height)
        guard clamp else { return point }
        let halfWidth = max(80, menuSize.width / 2) + 8
        let halfHeight = max(17, menuSize.height / 2)
        let top = windowInsets.top + 54 + halfHeight
        let bottom = size.height - windowInsets.bottom - 70 - halfHeight
        return CGPoint(x: min(max(point.x, halfWidth), max(halfWidth, size.width - halfWidth)),
                       y: min(max(point.y, top), max(top, bottom)))
    }

    private func clearSelection() {
        selectedText = ""
        selectedTranslation = ""
        selectedLink = ""
        selectedIndices = []
        selectedRange = nil
        selectedBox = nil
        selectedSegments = []
        selectionAnchor = nil
    }

    /// Puts plain text on the system clipboard so any app's keyboard can
    /// paste it (including the keyboard's paste suggestion). OCR line breaks
    /// inside a selection are joined, so a pasted sentence is not cut into
    /// screen lines.
    private func copyText(_ raw: String, note: String, joinLines: Bool = true) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if joinLines {
            let cjk = text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
            let paragraphs = text.components(separatedBy: "\n\n")
            text = paragraphs.map { $0.replacingOccurrences(of: "\n", with: cjk ? "" : " ") }
                .joined(separator: "\n")
        }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [:])
        saveMessage = note + "，可在任意输入框粘贴"
        let shown = saveMessage
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if saveMessage == shown { saveMessage = "" }
        }
    }

    private func copySelectedTranslation() {
        let original = selectedText
        let source = model.source
        let target = model.target
        guard !original.isEmpty, !copyingTranslation else { return }
        copyingTranslation = true
        saveMessage = "正在准备选中译文…"
        Task { @MainActor in
            defer { copyingTranslation = false }
            do {
                let value = try await model.translator.translate(original, source: source, target: target)
                guard selectedText == original, model.source == source, model.target == target else {
                    saveMessage = "选区或语言已变化，请重新复制译文"
                    return
                }
                selectedTranslation = value
                copyText(value, note: "已复制译文")
            } catch {
                saveMessage = "复制译文失败：\(error.localizedDescription)"
            }
        }
    }

    private func saveImage() {
        if displayMode == .selected && model.partialTranslations.isEmpty {
            saveMessage = "译文尚未生成"; return
        }
        guard let output = displayMode == .selected
            ? model.selectedTranslationImage : model.translatedImage else {
            saveMessage = "译文尚未生成"; return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in saveMessage = "未取得照片保存权限" }; return
            }
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: output) }) { success, error in
                Task { @MainActor in saveMessage = success ? "已保存到照片" : "保存失败：\(error?.localizedDescription ?? "未知错误")" }
            }
        }
    }

    private func searchSelectedText() {
        guard !selectedText.isEmpty,
              let encoded = selectedText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    private func translateSelection() {
        guard !selectedSegments.isEmpty, selectedLink.isEmpty else { return }
        let segments = selectedSegments
        clearSelection()
        displayMode = .selected
        Task { await model.translateSelected(segments: segments) }
    }
}

private struct LensSharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ImageShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// VisionKit supplies native multi-line text selection handles and image-subject copy
/// on the image in both original and translated modes. The view scales the entire
/// screenshot into the available screen and supports pinch zoom and panning.
struct LiveTextImageView: UIViewRepresentable {
    let image: UIImage
    let viewport: CGSize
    let blocks: [TextBlock]
    let partialTranslations: [String: LensPartialTranslation]
    let autoFitSnap: Bool
    var dragSnapsSentences = false
    let zoomEnabled: Bool
    let zoomResetToken: Int
    let showProgressOverlay: Bool
    let showSelectedProgressOverlay: Bool
    let analysisEnabled: Bool
    @Binding var selectedText: String
    @Binding var selectedTranslation: String
    @Binding var selectedLink: String
    @Binding var selectedIndices: [Int]
    @Binding var selectedRange: OCRTextRange?
    @Binding var selectedBox: CGRect?
    @Binding var selectedSegments: [LensSelectionSegment]
    @Binding var selectionAnchor: CGPoint?

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedText: $selectedText, selectedTranslation: $selectedTranslation,
                    selectedLink: $selectedLink,
                    selectedIndices: $selectedIndices, selectedRange: $selectedRange,
                    selectedBox: $selectedBox, selectedSegments: $selectedSegments,
                    selectionAnchor: $selectionAnchor)
    }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .black
        // 1x fits the whole screenshot. Allow a smaller custom size as well.
        scroll.minimumZoomScale = 0.45
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.delegate = context.coordinator
        context.coordinator.scroll = scroll
        scroll.contentInsetAdjustmentBehavior = .never
        let photo = UIImageView()
        photo.contentMode = .scaleAspectFit
        photo.isUserInteractionEnabled = true
        photo.image = image
        scroll.addSubview(photo)
        context.coordinator.photo = photo
        let overlay = UIView()
        overlay.isUserInteractionEnabled = false
        photo.addSubview(overlay)
        context.coordinator.overlay = overlay
        let selectionOverlay = UIView()
        selectionOverlay.isUserInteractionEnabled = false
        photo.addSubview(selectionOverlay)
        context.coordinator.selectionOverlay = selectionOverlay
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.selectByTapping(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        photo.addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.enterNativeSelection(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        doubleTap.cancelsTouchesInView = false
        photo.addGestureRecognizer(doubleTap)
        let drag = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.selectByDragging(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = context.coordinator
        drag.cancelsTouchesInView = false
        photo.addGestureRecognizer(drag)
        scroll.panGestureRecognizer.require(toFail: drag)
        let interaction = ImageAnalysisInteraction(context.coordinator)
        interaction.preferredInteractionTypes = [.textSelection, .imageSubject]
        photo.addInteraction(interaction)
        context.coordinator.interaction = interaction
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let photo = context.coordinator.photo else { return }
        let size = viewport
        guard size.width > 0, size.height > 0 else { return }
        context.coordinator.setAutoFitSnap(autoFitSnap)
        context.coordinator.dragSnapsSentences = dragSnapsSentences
        if context.coordinator.zoomEnabled != zoomEnabled {
            context.coordinator.zoomEnabled = zoomEnabled
            if !zoomEnabled { context.coordinator.resetZoom(animated: false) }
        }
        scroll.pinchGestureRecognizer?.isEnabled = zoomEnabled
        if context.coordinator.zoomResetToken != zoomResetToken {
            context.coordinator.zoomResetToken = zoomResetToken
            context.coordinator.resetZoom(animated: true)
        }
        let imageChanged = context.coordinator.lastImage !== image
        let imageSizeChanged = context.coordinator.lastImage.map {
            abs($0.size.width - image.size.width) > 0.5
                || abs($0.size.height - image.size.height) > 0.5
        } ?? true
        if context.coordinator.viewport != size || imageSizeChanged {
            // A translation changes UIImage identity, but it must not change the
            // reader's zoom or scroll position for the same screenshot.
            if context.coordinator.viewport != .zero {
                context.coordinator.resetZoom(animated: false)
            }
            let fit = min(size.width / image.size.width, size.height / image.size.height)
            let fitted = CGSize(width: image.size.width * fit, height: image.size.height * fit)
            photo.frame = CGRect(x: max(0, (size.width - fitted.width) / 2),
                                 y: max(0, (size.height - fitted.height) / 2),
                                 width: fitted.width, height: fitted.height)
            scroll.contentSize = size
            context.coordinator.viewport = size
        }
        updateProgressOverlay(context.coordinator, photo: photo)
        context.coordinator.blocks = blocks
        context.coordinator.partialTranslations = partialTranslations
        context.coordinator.selectionOverlay?.frame = photo.bounds
        context.coordinator.refreshSelectionHighlight()
        context.coordinator.analysisEnabled = analysisEnabled
        if imageChanged {
            context.coordinator.clearDragSelection()
            context.coordinator.pendingTap = nil
            context.coordinator.lastImage = image
            context.coordinator.lastAnalyzedImage = nil
            photo.image = image
            context.coordinator.interaction?.analysis = nil
        }
        guard analysisEnabled else {
            context.coordinator.interaction?.analysis = nil
            context.coordinator.lastAnalyzedImage = nil
            return
        }
        if !blocks.isEmpty, let pendingTap = context.coordinator.pendingTap {
            context.coordinator.pendingTap = nil
            Task { @MainActor in context.coordinator.select(atNormalizedPoint: pendingTap) }
        }
        guard ImageAnalyzer.isSupported, context.coordinator.lastAnalyzedImage !== image else { return }
        context.coordinator.lastAnalyzedImage = image
        let analyzer = context.coordinator.analyzer
        Task { @MainActor in
            do {
                let result = try await analyzer.analyze(image, configuration: .init([.text, .visualLookUp]))
                if context.coordinator.lastImage === image && context.coordinator.analysisEnabled {
                    context.coordinator.interaction?.analysis = result
                }
            } catch {
                if context.coordinator.lastImage === image {
                    context.coordinator.lastAnalyzedImage = nil
                }
            }
        }
    }
    private func updateProgressOverlay(_ coordinator: Coordinator, photo: UIImageView) {
        guard let overlay = coordinator.overlay else { return }
        overlay.frame = photo.bounds
        let visible: [(id: String, text: String, box: CGRect)]
        if showProgressOverlay {
            visible = blocks.compactMap { block in
                guard !block.translated.isEmpty, block.translated != block.original else { return nil }
                return ("full:\(block.id.uuidString)", block.translated, block.box)
            }
        } else if showSelectedProgressOverlay {
            visible = partialTranslations.map { key, item in
                (key, item.text, item.box)
            }
        } else {
            visible = []
        }
        let visibleIDs = Set(visible.map(\.id))
        for id in coordinator.overlayLabels.keys.filter({ !visibleIDs.contains($0) }) {
            coordinator.overlayLabels.removeValue(forKey: id)?.removeFromSuperview()
        }
        for item in visible {
            let rect = CGRect(x: item.box.minX * photo.bounds.width,
                              y: (1 - item.box.maxY) * photo.bounds.height,
                              width: item.box.width * photo.bounds.width,
                              height: item.box.height * photo.bounds.height)
            let label: UILabel
            if let existing = coordinator.overlayLabels[item.id] {
                label = existing
            } else {
                label = UILabel()
                label.textColor = .label
                label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.98)
                label.numberOfLines = 0
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.65
                coordinator.overlayLabels[item.id] = label
                overlay.addSubview(label)
            }
            if label.text != item.text { label.text = item.text }
            let frame = rect.insetBy(dx: -1, dy: -1)
            if label.frame != frame {
                label.frame = frame
                label.font = .systemFont(ofSize: max(11, min(22, rect.height * 0.8)))
            }
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, ImageAnalysisInteractionDelegate,
                             UIGestureRecognizerDelegate {
        weak var scroll: UIScrollView?
        weak var photo: UIImageView?
        weak var overlay: UIView?
        weak var selectionOverlay: UIView?
        var interaction: ImageAnalysisInteraction?
        let analyzer = ImageAnalyzer()
        var lastImage: UIImage?
        var lastAnalyzedImage: UIImage?
        var analysisEnabled = false
        var overlayLabels: [String: UILabel] = [:]
        var viewport = CGSize.zero
        var autoFitSnap = true
        var zoomEnabled = true
        var zoomResetToken = 0
        private var pendingAutoFit: DispatchWorkItem?
        var blocks: [TextBlock] = []
        var partialTranslations: [String: LensPartialTranslation] = [:]
        var dragStart: Int?
        var dragEnd: Int?
        var pendingDragStart: Int?
        var pendingDragPoint: CGPoint?
        var dragStartPoint: CGPoint?
        var pendingTap: CGPoint?
        private var lastCustomTapAt = Date.distantPast
        private var linkSegments: [OCRLinkSegment] = []
        var selectedText: Binding<String>
        var selectedTranslation: Binding<String>
        var selectedLink: Binding<String>
        var selectedIndices: Binding<[Int]>
        var selectedRange: Binding<OCRTextRange?>
        var selectedBox: Binding<CGRect?>
        var selectedSegments: Binding<[LensSelectionSegment]>
        var selectionAnchor: Binding<CGPoint?>
        init(selectedText: Binding<String>, selectedTranslation: Binding<String>,
             selectedLink: Binding<String>,
             selectedIndices: Binding<[Int]>, selectedRange: Binding<OCRTextRange?>,
             selectedBox: Binding<CGRect?>,
             selectedSegments: Binding<[LensSelectionSegment]>,
             selectionAnchor: Binding<CGPoint?>) {
            self.selectedText = selectedText
            self.selectedTranslation = selectedTranslation
            self.selectedLink = selectedLink
            self.selectedIndices = selectedIndices
            self.selectedRange = selectedRange
            self.selectedBox = selectedBox
            self.selectedSegments = selectedSegments
            self.selectionAnchor = selectionAnchor
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let photo else { return }
            // Keep an image smaller than the viewport centered while pinching in.
            photo.center = CGPoint(x: max(scrollView.bounds.width,
                                          scrollView.contentSize.width) / 2,
                                   y: max(scrollView.bounds.height,
                                          scrollView.contentSize.height) / 2)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            pendingAutoFit?.cancel()
            pendingAutoFit = nil
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            // Extra scroll room lets the first and last lines move clear of the
            // floating controls while the image is enlarged.
            scrollView.contentInset = scale > 1.01
                ? UIEdgeInsets(top: 110, left: 0, bottom: 170, right: 0) : .zero
            scheduleAutoFit()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pendingAutoFit?.cancel()
            pendingAutoFit = nil
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { scheduleAutoFit() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scheduleAutoFit()
        }

        func resetZoom(animated: Bool) {
            pendingAutoFit?.cancel()
            pendingAutoFit = nil
            guard let scroll else { return }
            scroll.setZoomScale(1, animated: animated)
            scroll.contentInset = .zero
            scroll.setContentOffset(.zero, animated: animated)
        }

        func setAutoFitSnap(_ enabled: Bool) {
            guard autoFitSnap != enabled else { return }
            autoFitSnap = enabled
            if enabled {
                scheduleAutoFit()
            } else {
                pendingAutoFit?.cancel()
                pendingAutoFit = nil
            }
        }

        private func scheduleAutoFit() {
            pendingAutoFit?.cancel()
            pendingAutoFit = nil
            guard autoFitSnap, let scroll,
                  abs(scroll.zoomScale - 1) > 0.01,
                  abs(scroll.zoomScale - 1) <= 0.12 else { return }
            let work = DispatchWorkItem { [weak self, weak scroll] in
                guard let self, let scroll, self.autoFitSnap,
                      !scroll.isZooming, !scroll.isDragging, !scroll.isDecelerating,
                      abs(scroll.zoomScale - 1) > 0.01,
                      abs(scroll.zoomScale - 1) <= 0.12 else { return }
                self.resetZoom(animated: true)
            }
            pendingAutoFit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        func textSelectionDidChange(_ interaction: ImageAnalysisInteraction) {
            // Native Live Text owns long-press selection handles and its edit menu.
            // A native callback can arrive just after our first tap. Do not erase
            // the tap selection before its copy menu has appeared.
            guard Date().timeIntervalSince(lastCustomTapAt) > 0.65 else { return }
            clearCustomSelection()
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let photo else { return false }
            let point = touch.location(in: photo)
            // Keep the native Live Text button at the lower right unobstructed.
            if point.x > photo.bounds.width - 90 && point.y > photo.bounds.height - 110 { return false }
            if gestureRecognizer is UITapGestureRecognizer { return true }
            let index = index(at: point, photo: photo, nearest: false)
            if gestureRecognizer is UIPanGestureRecognizer {
                pendingDragStart = index
                pendingDragPoint = point
            }
            return index != nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UITapGestureRecognizer
        }
        @objc func selectByTapping(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let photo else { return }
            let point = gesture.location(in: photo)
            if blocks.isEmpty {
                pendingTap = CGPoint(x: point.x / max(1, photo.bounds.width),
                                     y: point.y / max(1, photo.bounds.height))
                return
            }
            select(at: point, in: photo)
        }
        @objc func enterNativeSelection(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            lastCustomTapAt = .distantPast
            clearCustomSelection()
        }
        func select(atNormalizedPoint point: CGPoint) {
            guard let photo else { return }
            select(at: CGPoint(x: point.x * photo.bounds.width,
                               y: point.y * photo.bounds.height), in: photo)
        }
        private func select(at point: CGPoint, in photo: UIImageView) {
            guard let index = index(at: point, photo: photo, nearest: false)
                    ?? nearbyIndex(at: point, photo: photo) else { return }
            lastCustomTapAt = Date()
            let links = OCRLinkDetector.links(in: blocks)
            if let link = links.first(where: { link in
                link.segments.contains { segment in
                    segment.index == index && linkRect(for: segment, in: photo)
                        .insetBy(dx: -7, dy: -5).contains(point)
                }
            }) {
                applyLinkSelection(link, at: point)
                return
            }
            let offset = characterOffset(at: point, in: index, photo: photo)
            // A number (phone, amount, code, date) is selected on its own.
            if let number = numberSegment(in: index, at: offset) {
                applyPlainSelection(number, at: point)
                return
            }
            // One tap selects the sentence under the finger; tapping the same
            // sentence again widens it to the whole paragraph, and a third tap
            // goes back to the sentence.
            let sentences = sentenceMap()
            guard let sentence = sentenceIndex(line: index, offset: offset, in: sentences) else { return }
            if selectedSentences == sentence...sentence, sentenceTapCount == 1 {
                let paragraph = paragraphRange(around: index)
                applySelection(from: paragraph.lowerBound, to: paragraph.upperBound, at: point)
                selectedSentences = sentence...sentence
                sentenceTapCount = 2
            } else {
                applySegments(sentences[sentence], anchor: point)
                selectedSentences = sentence...sentence
                sentenceTapCount = 1
            }
        }

        // MARK: Sentence map

        /// Selected sentence span (indices into sentenceMap) for tap toggling.
        private var selectedSentences: ClosedRange<Int>?
        private var sentenceTapCount = 0
        private var cachedSentences: [[OCRLinkSegment]] = []
        private var cachedSentenceKey = ""

        /// Lines are joined per paragraph and split at sentence ends
        /// (。！？；!?; and a period followed by a space or line end). A sentence
        /// may cross several lines; each part is one OCRLinkSegment.
        private func sentenceMap() -> [[OCRLinkSegment]] {
            let key = "\(blocks.count)|\(blocks.first?.id.uuidString ?? "")|\(blocks.last?.id.uuidString ?? "")"
            if key == cachedSentenceKey { return cachedSentences }
            var result: [[OCRLinkSegment]] = []
            var current: [OCRLinkSegment] = []
            let hardEnds: Set<String> = ["。", "！", "？", "；", "!", "?", ";", "…"]
            let closers: Set<String> = ["”", "’", "\"", "'", "）", ")", "」", "』", "】", "]", "》"]
            func flush() {
                let kept = current.filter { $0.length > 0 }
                if !kept.isEmpty { result.append(kept) }
                current = []
            }
            for index in blocks.indices {
                let line = blocks[index].original as NSString
                var segmentStart = 0
                var position = 0
                while position < line.length {
                    let range = line.rangeOfComposedCharacterSequence(at: position)
                    let character = line.substring(with: range)
                    position = NSMaxRange(range)
                    var ends = hardEnds.contains(character)
                    if character == "." || character == "．" {
                        let atLineEnd = position >= line.length
                        let nextIsSpace = !atLineEnd && line.substring(with: line.rangeOfComposedCharacterSequence(at: position))
                            .trimmingCharacters(in: .whitespaces).isEmpty
                        ends = atLineEnd || nextIsSpace
                    }
                    guard ends else { continue }
                    while position < line.length {
                        let next = line.rangeOfComposedCharacterSequence(at: position)
                        guard closers.contains(line.substring(with: next)) || hardEnds.contains(line.substring(with: next)) else { break }
                        position = NSMaxRange(next)
                    }
                    current.append(trimmedSegment(index: index, start: segmentStart, end: position, in: line))
                    flush()
                    segmentStart = position
                }
                if segmentStart < line.length {
                    current.append(trimmedSegment(index: index, start: segmentStart, end: line.length, in: line))
                }
                let paragraphEnds = index + 1 >= blocks.count || !continues(blocks[index], blocks[index + 1])
                if paragraphEnds { flush() }
            }
            flush()
            cachedSentences = result
            cachedSentenceKey = key
            return result
        }

        private func trimmedSegment(index: Int, start: Int, end: Int, in line: NSString) -> OCRLinkSegment {
            var first = start
            var last = end
            while first < last, line.substring(with: NSRange(location: first, length: 1)).trimmingCharacters(in: .whitespaces).isEmpty { first += 1 }
            while last > first, line.substring(with: NSRange(location: last - 1, length: 1)).trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
            return OCRLinkSegment(index: index, start: first, length: last - first)
        }

        private func sentenceIndex(line: Int, offset: Int, in sentences: [[OCRLinkSegment]]) -> Int? {
            var lastOnLine: Int?
            for (number, sentence) in sentences.enumerated() {
                for segment in sentence where segment.index == line {
                    if offset < segment.start + segment.length { return number }
                    lastOnLine = number
                }
            }
            return lastOnLine
        }

        /// Digits with separators such as 138-0013-8000, 12,345.60, 2026/11/05.
        private func numberSegment(in index: Int, at offset: Int) -> OCRLinkSegment? {
            guard blocks.indices.contains(index) else { return nil }
            let text = blocks[index].original
            let line = text as NSString
            guard let regex = try? NSRegularExpression(pattern: #"[+＋]?[0-9０-９][0-9０-９\-–.,:/ ]*[0-9０-９]%?|[0-9０-９]{1,}%?"#) else { return nil }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: line.length)) {
                let digits = line.substring(with: match.range).filter(\.isNumber).count
                guard digits >= 3 else { continue }
                if offset >= match.range.location && offset <= NSMaxRange(match.range) {
                    // Only when the number is a distinct part of the line.
                    guard match.range.length < line.length || line.length <= 24 else { return nil }
                    return OCRLinkSegment(index: index, start: match.range.location, length: match.range.length)
                }
            }
            return nil
        }

        /// Vertically close (normal line spacing, not a paragraph gap) and
        /// horizontally aligned lines continue the same paragraph.
        private func continues(_ upper: TextBlock, _ lower: TextBlock) -> Bool {
            // Vision boxes are bottom-left based: the upper line has larger y.
            let gap = upper.box.minY - lower.box.maxY
            let height = max(upper.box.height, lower.box.height)
            let overlap = max(0, min(upper.box.maxX, lower.box.maxX) - max(upper.box.minX, lower.box.minX))
            let shorter = max(0.001, min(upper.box.width, lower.box.width))
            let aligned = abs(upper.box.minX - lower.box.minX) < 0.05
            return gap > -height * 0.5 && gap < height * 0.75
                && (aligned || overlap / shorter > 0.6)
        }

        private func paragraphRange(around index: Int) -> ClosedRange<Int> {
            var start = index
            var end = index
            while start > 0, continues(blocks[start - 1], blocks[start]) { start -= 1 }
            while end + 1 < blocks.count, continues(blocks[end], blocks[end + 1]) { end += 1 }
            return start...end
        }
        @objc func selectByDragging(_ gesture: UIPanGestureRecognizer) {
            guard let photo else { return }
            let point = gesture.location(in: photo)
            switch gesture.state {
            case .began:
                dragStart = pendingDragStart
                dragEnd = dragStart
                dragStartPoint = pendingDragPoint ?? point
            case .changed, .ended:
                guard dragStart != nil else { return }
                dragEnd = index(at: point, photo: photo, nearest: true) ?? dragEnd
                if gesture.state == .ended { pendingDragStart = nil }
            default: return
            }
            guard let dragStart, let dragEnd, let dragStartPoint else { return }
            lastCustomTapAt = Date()
            let sentences = sentenceMap()
            let firstOffset = characterOffset(at: dragStartPoint, in: dragStart, photo: photo)
            let lastOffset = characterOffset(at: point, in: dragEnd, photo: photo)
            if dragSnapsSentences {
                // Option: dragging adds whole sentences one by one.
                if let first = sentenceIndex(line: dragStart, offset: firstOffset, in: sentences),
                   let last = sentenceIndex(line: dragEnd, offset: lastOffset, in: sentences) {
                    let span = min(first, last)...max(first, last)
                    if span != selectedSentences || sentenceTapCount != 1 || gesture.state == .ended {
                        applySegments(mergedSegments(span.flatMap { sentences[$0] }), anchor: point)
                        selectedSentences = span
                        sentenceTapCount = 1
                    }
                }
            } else {
                // Free selection: the range follows the finger character by
                // character, so any custom stretch can be chosen. The start is
                // pulled back to the sentence start when the finger landed a
                // little late (or at least to the start of the word), and the
                // end is completed to the end of the word / sentence.
                var from = TextPosition(line: dragStart, offset: firstOffset)
                var to = TextPosition(line: dragEnd, offset: lastOffset)
                if to < from { swap(&from, &to) }
                if from == to {
                    if gesture.state == .ended { select(at: point, in: photo) }
                } else {
                    let start = snappedStart(from, sentences: sentences)
                    let finish = snappedEnd(to, sentences: sentences)
                    if start < finish {
                        applySegments(segments(from: start, to: finish), anchor: point)
                        selectedSentences = nil
                        sentenceTapCount = 0
                    }
                }
            }
            if gesture.state == .ended { self.dragStartPoint = nil; pendingDragPoint = nil }
        }

        /// Set from 设置 → 智能镜头 → 拖动选择.
        var dragSnapsSentences = false

        private struct TextPosition: Comparable {
            let line: Int
            let offset: Int
            static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
                lhs.line != rhs.line ? lhs.line < rhs.line : lhs.offset < rhs.offset
            }
        }

        private func mergedSegments(_ input: [OCRLinkSegment]) -> [OCRLinkSegment] {
            var merged: [OCRLinkSegment] = []
            for segment in input {
                if let previous = merged.last, previous.index == segment.index {
                    merged[merged.count - 1] = OCRLinkSegment(
                        index: segment.index, start: previous.start,
                        length: segment.start + segment.length - previous.start)
                } else {
                    merged.append(segment)
                }
            }
            return merged
        }

        private func segments(from start: TextPosition, to end: TextPosition) -> [OCRLinkSegment] {
            var result: [OCRLinkSegment] = []
            for line in start.line...end.line where blocks.indices.contains(line) {
                let length = (blocks[line].original as NSString).length
                let begin = line == start.line ? min(start.offset, length) : 0
                let finish = line == end.line ? min(end.offset, length) : length
                if finish > begin {
                    result.append(trimmedSegment(index: line, start: begin, end: finish,
                                                 in: blocks[line].original as NSString))
                }
            }
            return result.filter { $0.length > 0 }
        }

        /// Characters from the sentence start to `position`, and the sentence length.
        private func sentenceProgress(_ position: TextPosition, in sentence: [OCRLinkSegment]) -> (before: Int, total: Int) {
            var before = 0
            var total = 0
            for segment in sentence {
                total += segment.length
                if segment.index < position.line {
                    before += segment.length
                } else if segment.index == position.line {
                    before += min(segment.length, max(0, position.offset - segment.start))
                }
            }
            return (before, total)
        }

        private func isWordCharacter(_ line: NSString, _ offset: Int) -> Bool {
            guard offset >= 0, offset < line.length,
                  let scalar = UnicodeScalar(Int(line.character(at: offset))) else { return false }
            // CJK has no word breaks; only Latin-like letters and digits form words.
            return scalar.value < 0x2E80 && CharacterSet.alphanumerics.contains(scalar)
        }

        private func snappedStart(_ position: TextPosition, sentences: [[OCRLinkSegment]]) -> TextPosition {
            if let number = sentenceIndex(line: position.line, offset: position.offset, in: sentences),
               let first = sentences[number].first {
                let progress = sentenceProgress(position, in: sentences[number])
                if progress.before <= max(6, progress.total / 4) {
                    return TextPosition(line: first.index, offset: first.start)
                }
            }
            let line = blocks[position.line].original as NSString
            var offset = min(position.offset, line.length)
            if isWordCharacter(line, offset) {
                while offset > 0, isWordCharacter(line, offset - 1) { offset -= 1 }
            }
            return TextPosition(line: position.line, offset: offset)
        }

        private func snappedEnd(_ position: TextPosition, sentences: [[OCRLinkSegment]]) -> TextPosition {
            if let number = sentenceIndex(line: position.line, offset: max(0, position.offset - 1), in: sentences),
               let last = sentences[number].last {
                let progress = sentenceProgress(position, in: sentences[number])
                if progress.total - progress.before <= max(4, progress.total / 6) {
                    return TextPosition(line: last.index, offset: last.start + last.length)
                }
            }
            let line = blocks[position.line].original as NSString
            var offset = min(position.offset, line.length)
            if offset > 0, isWordCharacter(line, offset - 1) {
                while isWordCharacter(line, offset) { offset += 1 }
            }
            return TextPosition(line: position.line, offset: offset)
        }
        /// Selects arbitrary line pieces (a sentence or several sentences).
        private func applySegments(_ input: [OCRLinkSegment], anchor endPoint: CGPoint) {
            guard let photo, let scroll else { return }
            let segments = input.filter { blocks.indices.contains($0.index) && $0.length > 0 }
            guard !segments.isEmpty else { return }
            let pieces = segments.map { segment in
                (blocks[segment.index].original as NSString)
                    .substring(with: NSRange(location: segment.start, length: segment.length))
            }
            let rects = segments.map { linkRect(for: $0, in: photo) }
            let rect = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let box = CGRect(x: rect.minX / photo.bounds.width,
                             y: 1 - rect.maxY / photo.bounds.height,
                             width: rect.width / photo.bounds.width,
                             height: rect.height / photo.bounds.height)
            linkSegments = segments
            selectedLink.wrappedValue = ""
            // A sentence broken over lines is copied as one sentence.
            selectedText.wrappedValue = pieces.enumerated().reduce(into: "") { text, item in
                guard item.offset > 0 else { text = item.element; return }
                let previous = segments[item.offset - 1]
                let sameParagraph = segments[item.offset].index == previous.index + 1
                    && continues(blocks[previous.index], blocks[segments[item.offset].index])
                let cjk = text.unicodeScalars.last.map { $0.value >= 0x2E80 } ?? false
                text += sameParagraph ? (cjk || text.hasSuffix("-") ? "" : " ") : "\n"
                text += item.element
            }
            selectedTranslation.wrappedValue = partialTranslations[LensPartialTranslation.key(for: box)]?.text ?? ""
            selectedIndices.wrappedValue = segments.map(\.index)
            selectedRange.wrappedValue = segments.count == 1
                ? OCRTextRange(index: segments[0].index, start: segments[0].start,
                               length: segments[0].length, box: box) : nil
            selectedBox.wrappedValue = box
            selectedSegments.wrappedValue = zip(segments, pieces).map { segment, text in
                let itemRect = linkRect(for: segment, in: photo)
                return LensSelectionSegment(
                    text: text,
                    box: CGRect(x: itemRect.minX / photo.bounds.width,
                                y: 1 - itemRect.maxY / photo.bounds.height,
                                width: itemRect.width / photo.bounds.width,
                                height: itemRect.height / photo.bounds.height))
            }
            selectionAnchor.wrappedValue = photo.convert(endPoint, to: scroll)
            refreshSelectionHighlight()
        }
        private func applySelection(from start: Int, to end: Int, at point: CGPoint) {
            guard let photo, let scroll else { return }
            linkSegments = []
            selectedLink.wrappedValue = ""
            selectedRange.wrappedValue = nil
            dragStart = start
            dragEnd = end
            let range = min(start, end)...max(start, end)
            selectedText.wrappedValue = range.map { blocks[$0].original }.joined(separator: "\n")
            selectedTranslation.wrappedValue = range.map {
                blocks[$0].translated.isEmpty ? blocks[$0].original : blocks[$0].translated
            }.joined(separator: "\n")
            selectedIndices.wrappedValue = Array(range)
            selectedBox.wrappedValue = range.map { blocks[$0].box }
                .reduce(nil as CGRect?) { previous, box in
                    previous.map { $0.union(box) } ?? box
                }
            selectedSegments.wrappedValue = range.map {
                LensSelectionSegment(text: blocks[$0].original, box: blocks[$0].box)
            }
            selectionAnchor.wrappedValue = photo.convert(point, to: scroll)
            refreshSelectionHighlight()
        }
        private func applyLinkSelection(_ link: OCRDetectedLink, at point: CGPoint) {
            guard let photo, let scroll else { return }
            clearDragSelection()
            linkSegments = link.segments
            selectedLink.wrappedValue = link.url
            selectedText.wrappedValue = link.url
            selectedTranslation.wrappedValue = ""
            selectedIndices.wrappedValue = Array(Set(link.segments.map(\.index))).sorted()
            selectedRange.wrappedValue = nil
            selectedBox.wrappedValue = nil
            selectedSegments.wrappedValue = []
            selectionAnchor.wrappedValue = photo.convert(point, to: scroll)
            refreshSelectionHighlight()
        }
        private func applyPlainSelection(_ segment: OCRLinkSegment, at point: CGPoint) {
            guard let photo, let scroll, blocks.indices.contains(segment.index) else { return }
            clearDragSelection()
            let line = blocks[segment.index].original as NSString
            let text = line.substring(with: NSRange(location: segment.start, length: segment.length))
            let rect = linkRect(for: segment, in: photo)
            let box = CGRect(x: rect.minX / photo.bounds.width,
                             y: 1 - rect.maxY / photo.bounds.height,
                             width: rect.width / photo.bounds.width,
                             height: rect.height / photo.bounds.height)
            let range = OCRTextRange(index: segment.index, start: segment.start,
                                     length: segment.length, box: box)
            linkSegments = [segment]
            selectedLink.wrappedValue = ""
            selectedText.wrappedValue = text
            selectedTranslation.wrappedValue = partialTranslations[range.key]?.text
                ?? (segment.length == line.length ? blocks[segment.index].translated : "")
            selectedIndices.wrappedValue = [segment.index]
            selectedRange.wrappedValue = range
            selectedBox.wrappedValue = box
            selectedSegments.wrappedValue = [LensSelectionSegment(text: text, box: box)]
            selectionAnchor.wrappedValue = photo.convert(point, to: scroll)
            refreshSelectionHighlight()
        }
        private func linkRect(for segment: OCRLinkSegment, in photo: UIImageView) -> CGRect {
            let block = blocks[segment.index]
            let box = block.box
            let line = CGRect(x: box.minX * photo.bounds.width,
                              y: (1 - box.maxY) * photo.bounds.height,
                              width: box.width * photo.bounds.width,
                              height: box.height * photo.bounds.height)
            let textLine = block.original as NSString
            let font = UIFont.systemFont(ofSize: 16)
            func width(_ text: String) -> CGFloat {
                (text as NSString).size(withAttributes: [.font: font]).width
            }
            let total = max(1, width(block.original))
            let start = width(textLine.substring(to: min(segment.start, textLine.length))) / total
            let end = width(textLine.substring(to: min(segment.start + segment.length, textLine.length))) / total
            return CGRect(x: line.minX + line.width * start, y: line.minY,
                          width: max(3, line.width * (end - start)), height: line.height)
        }
        private func characterOffset(at point: CGPoint, in index: Int, photo: UIImageView) -> Int {
            guard blocks.indices.contains(index) else { return 0 }
            let text = blocks[index].original
            let box = blocks[index].box
            let line = CGRect(x: box.minX * photo.bounds.width,
                              y: (1 - box.maxY) * photo.bounds.height,
                              width: box.width * photo.bounds.width,
                              height: box.height * photo.bounds.height)
            let fraction = min(1, max(0, (point.x - line.minX) / max(1, line.width)))
            let font = UIFont.systemFont(ofSize: 16)
            let totalWidth = max(1, (text as NSString).size(withAttributes: [.font: font]).width)
            var prefix = ""
            var offset = 0
            for character in text {
                let next = prefix + String(character)
                let nextWidth = (next as NSString).size(withAttributes: [.font: font]).width
                if fraction * totalWidth < nextWidth - (nextWidth - (prefix as NSString)
                    .size(withAttributes: [.font: font]).width) / 2 { return offset }
                prefix = next
                offset += String(character).utf16.count
            }
            return offset
        }
        private func index(at point: CGPoint, photo: UIImageView, nearest: Bool) -> Int? {
            guard !blocks.isEmpty, photo.bounds.width > 0, photo.bounds.height > 0 else { return nil }
            let rects = blocks.map { block in
                CGRect(x: block.box.minX * photo.bounds.width,
                       y: (1 - block.box.maxY) * photo.bounds.height,
                       width: block.box.width * photo.bounds.width,
                       height: block.box.height * photo.bounds.height)
            }
            if let hit = rects.firstIndex(where: { $0.insetBy(dx: -6, dy: -6).contains(point) }) { return hit }
            guard nearest else { return nil }
            return rects.indices.min { lhs, rhs in
                hypot(rects[lhs].midX - point.x, rects[lhs].midY - point.y)
                    < hypot(rects[rhs].midX - point.x, rects[rhs].midY - point.y)
            }
        }
        private func nearbyIndex(at point: CGPoint, photo: UIImageView) -> Int? {
            guard let candidate = index(at: point, photo: photo, nearest: true) else { return nil }
            let box = blocks[candidate].box
            let rect = CGRect(x: box.minX * photo.bounds.width,
                              y: (1 - box.maxY) * photo.bounds.height,
                              width: box.width * photo.bounds.width,
                              height: box.height * photo.bounds.height)
            let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
            let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
            return hypot(dx, dy) <= 22 ? candidate : nil
        }
        func clearDragSelection() {
            dragStart = nil
            dragEnd = nil
            pendingDragStart = nil
            pendingDragPoint = nil
            dragStartPoint = nil
            linkSegments = []
            selectedSentences = nil
            sentenceTapCount = 0
            selectionOverlay?.subviews.forEach { $0.removeFromSuperview() }
        }
        private func clearCustomSelection() {
            selectedText.wrappedValue = ""
            selectedTranslation.wrappedValue = ""
            selectedLink.wrappedValue = ""
            selectedIndices.wrappedValue = []
            selectedRange.wrappedValue = nil
            selectedBox.wrappedValue = nil
            selectedSegments.wrappedValue = []
            selectionAnchor.wrappedValue = nil
            clearDragSelection()
        }
        func refreshSelectionHighlight() {
            guard let photo, let selectionOverlay else { return }
            selectionOverlay.subviews.forEach { $0.removeFromSuperview() }
            if !linkSegments.isEmpty {
                for segment in linkSegments where blocks.indices.contains(segment.index) {
                    addHighlight(in: linkRect(for: segment, in: photo), to: selectionOverlay)
                }
                return
            }
            guard let dragStart, let dragEnd else { return }
            for index in min(dragStart, dragEnd)...max(dragStart, dragEnd) where blocks.indices.contains(index) {
                let box = blocks[index].box
                let rect = CGRect(x: box.minX * photo.bounds.width,
                                  y: (1 - box.maxY) * photo.bounds.height,
                                  width: box.width * photo.bounds.width,
                                  height: box.height * photo.bounds.height)
                addHighlight(in: rect, to: selectionOverlay)
            }
        }
        private func addHighlight(in rect: CGRect, to overlay: UIView) {
            let highlight = UIView(frame: rect.insetBy(dx: -2, dy: -2))
            highlight.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.22)
            highlight.layer.borderColor = UIColor.systemBlue.cgColor
            highlight.layer.borderWidth = 1
            highlight.layer.cornerRadius = 3
            overlay.addSubview(highlight)
        }
    }
}

private struct OCRLinkSegment {
    let index: Int
    let start: Int
    let length: Int
}

private struct OCRDetectedLink {
    let url: String
    let segments: [OCRLinkSegment]
}

private enum OCRLinkDetector {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?i)(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::[0-9]{2,5})?(?:[/?#][^\s<>"'，。；;]*)?"#
    )
    private static let urlCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    static func plainSegments(in blocks: [TextBlock], at index: Int,
                              links: [OCRDetectedLink]) -> [OCRLinkSegment] {
        guard blocks.indices.contains(index) else { return [] }
        let line = blocks[index].original as NSString
        let occupied = links.flatMap(\.segments).filter { $0.index == index }
            .map { NSRange(location: $0.start, length: $0.length) }
            .sorted { $0.location < $1.location }
        var gaps: [NSRange] = []
        var cursor = 0
        for used in occupied {
            if used.location > cursor {
                gaps.append(NSRange(location: cursor, length: used.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(used))
        }
        if cursor < line.length {
            gaps.append(NSRange(location: cursor, length: line.length - cursor))
        }
        return gaps.flatMap { gap in splitPlain(line, range: gap).map {
            OCRLinkSegment(index: index, start: $0.location, length: $0.length)
        } }
    }

    private static func splitPlain(_ line: NSString, range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var start: Int?
        var wasNumber = false
        let spaces = CharacterSet.whitespacesAndNewlines
        let digits = CharacterSet.decimalDigits
        func append(_ end: Int) {
            guard var first = start else { return }
            var last = end
            while first < last, let scalar = UnicodeScalar(Int(line.character(at: first))),
                  spaces.contains(scalar) { first += 1 }
            while last > first, let scalar = UnicodeScalar(Int(line.character(at: last - 1))),
                  spaces.contains(scalar) { last -= 1 }
            if last > first { result.append(NSRange(location: first, length: last - first)) }
            start = nil
        }
        for offset in range.location..<NSMaxRange(range) {
            let scalar = UnicodeScalar(Int(line.character(at: offset)))
            let character = scalar.map(String.init) ?? ""
            if "，。？！；;!?".contains(character), !character.isEmpty {
                if start == nil { start = offset }
                append(offset + 1)
                continue
            }
            let isNumber = scalar.map { digits.contains($0) } ?? false
            if start == nil {
                start = offset
                wasNumber = isNumber
            } else if isNumber != wasNumber, !(scalar.map { spaces.contains($0) } ?? false) {
                append(offset)
                start = offset
                wasNumber = isNumber
            }
        }
        append(NSMaxRange(range))
        return result
    }

    static func links(in blocks: [TextBlock]) -> [OCRDetectedLink] {
        var result: [OCRDetectedLink] = []
        for index in blocks.indices {
            let line = blocks[index].original as NSString
            for match in pattern.matches(in: blocks[index].original,
                                         range: NSRange(location: 0, length: line.length)) {
                var url = line.substring(with: match.range)
                var segments = [OCRLinkSegment(index: index, start: match.range.location,
                                               length: match.range.length)]
                // Vision may split a URL immediately after its scheme.
                if index > 0, match.range.location == 0 {
                    let preceding = blocks[index - 1].original as NSString
                    let scheme = preceding.range(of: #"https?://$"#, options: [.regularExpression, .caseInsensitive])
                    let gap = blocks[index - 1].box.minY - blocks[index].box.maxY
                    if scheme.location != NSNotFound,
                       gap > -0.015 && gap < 0.055,
                       blocks[index].box.minX <= blocks[index - 1].box.minX + 0.09 {
                        url = preceding.substring(with: scheme) + url
                        segments.insert(OCRLinkSegment(index: index - 1,
                                                       start: scheme.location,
                                                       length: scheme.length), at: 0)
                    }
                }
                var previous = index
                var previousFragmentReachesEnd = NSMaxRange(match.range) >= line.length - 1
                while segments.count < 5, previous + 1 < blocks.count,
                      previousFragmentReachesEnd {
                    let last = blocks[previous]
                    let next = blocks[previous + 1]
                    let gap = last.box.minY - next.box.maxY
                    let wraps = gap > -0.015 && gap < 0.055
                        && next.box.minX <= blocks[index].box.minX + 0.09
                    let likelyContinuation = "/-?=#%&".contains(url.last ?? " ")
                        || (url.count > 28 && last.box.maxX > 0.78)
                    guard wraps && likelyContinuation else { break }
                    let fragment = String(next.original.unicodeScalars.prefix {
                        urlCharacters.contains($0)
                    })
                    guard !fragment.isEmpty else { break }
                    url += fragment
                    segments.append(OCRLinkSegment(index: previous + 1, start: 0,
                                                   length: (fragment as NSString).length))
                    previous += 1
                    previousFragmentReachesEnd = (fragment as NSString).length >= (next.original as NSString).length - 1
                }
                while let last = url.last, ".,，。;；!！?？)]}".contains(last) {
                    url.removeLast()
                    if let tail = segments.last {
                        segments[segments.count - 1] = OCRLinkSegment(index: tail.index,
                                                                      start: tail.start,
                                                                      length: max(0, tail.length - 1))
                    }
                }
                let candidate = url.contains("://") ? url : "https://" + url
                guard let parsed = URLComponents(string: candidate),
                      let host = parsed.host, host.contains("."),
                      !segments.isEmpty else { continue }
                result.append(OCRDetectedLink(url: url, segments: segments))
            }
        }
        return result
    }
}
