import SwiftUI
import Translation
import Speech
import PhotosUI
import ImageIO

@MainActor final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()
    @Published private(set) var image: UIImage?
    private var file: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("wallpaper.jpg") }
    private init() { image = UIImage(contentsOfFile: file.path) }
    func set(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400
              ] as CFDictionary),
              let encoded = UIImage(cgImage: cg).jpegData(compressionQuality: 0.86) else {
            throw NSError(domain: "Wallpaper", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取这张图片"])
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: file, options: .atomic)
        image = UIImage(data: encoded)
    }
    func reset() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        image = nil
    }
}

struct GlassWallpaper: View {
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var wallpaper = WallpaperStore.shared
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Group {
                    if visualTheme == 5 { MistBackground() }
                    else if visualTheme == 4 || visualTheme == 3 || visualTheme == 2 { Color(uiColor: .systemGroupedBackground) }
                    else if let image = wallpaper.image { Image(uiImage: image).resizable().scaledToFill() }
                    else if visualTheme == 1 {
                        ZStack {
                            LinearGradient(colors: [Color(red: 0.62, green: 0.44, blue: 0.43), Color(red: 0.55, green: 0.36, blue: 0.39), Color(red: 0.22, green: 0.10, blue: 0.24), Color(red: 0.10, green: 0.03, blue: 0.17)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            RadialGradient(colors: [Color(red: 1, green: 0.62, blue: 0.51).opacity(0.38), .clear], center: .init(x: 0.75, y: 0.38), startRadius: 0, endRadius: geometry.size.width * 0.8)
                            RadialGradient(colors: [Color(red: 0.39, green: 0.15, blue: 0.37).opacity(0.46), .clear], center: .init(x: 0.2, y: 0.82), startRadius: 0, endRadius: geometry.size.width * 0.7)
                        }
                    } else { Image("GlassWallpaper").resizable().scaledToFill() }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                if visualTheme != 2 && visualTheme != 3 && visualTheme != 4 && visualTheme != 5 {
                    LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.08), .black.opacity(0.16)], startPoint: .top, endPoint: .bottom)
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

struct GlassPanel: ViewModifier {
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    var radius: CGFloat = 24
    // iOS 26 Liquid Glass. Each theme keeps its character:
    // 暖雾玻璃 (1) = warm tinted glass, 清透玻璃 (0) = clear glass lightly dimmed
    // for legibility over the wallpaper, other themes = standard regular glass.
    private var glass: Glass {
        switch visualTheme {
        case 1: return .regular.tint(Color(red: 0.55, green: 0.30, blue: 0.36).opacity(0.30))
        case 0: return .clear.tint(.black.opacity(0.16))
        default: return .regular
        }
    }
    @ViewBuilder func body(content: Content) -> some View {
        if visualTheme == 5 {
            // 雾面: porcelain cards instead of glass.
            content
                .background(RoundedRectangle(cornerRadius: radius + 6, style: .continuous).fill(Mist.porcelain.opacity(0.94)))
                .shadow(color: Color(red: 0.22, green: 0.27, blue: 0.36).opacity(0.12), radius: 16, y: 8)
                .foregroundStyle(Mist.ink)
        } else {
            content.glassEffect(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
extension View {
    func clearGlass(_ radius: CGFloat = 24) -> some View { modifier(GlassPanel(radius: radius)) }
}

struct GlassTabBar: View {
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @Binding var selection: Int
    private let titles = ["屏幕翻译", "智能镜头", "语音翻译"]
    private let symbols = ["text.viewfinder", "viewfinder", "waveform"]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { index in
                Button { selection = index } label: {
                    VStack(spacing: 2) {
                        Image(systemName: symbols[index]).font(.system(size: 16, weight: .light))
                        Text(titles[index]).font(.custom("AvenirNext-Medium", size: 11, relativeTo: .caption))
                    }
                    // Selected: white on a solid accent capsule (the coral-on-pink
                    // and blue-on-silver combinations were hard to read).
                    .foregroundStyle(index == selection ? Color.white : (visualTheme == 0 ? Color.primary.opacity(0.75) : Color.white.opacity(0.88)))
                    .fontWeight(index == selection ? .semibold : .regular)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(index == selection ? (visualTheme == 1 ? Color(red: 0.93, green: 0.45, blue: 0.40) : Color.blue).opacity(0.85) : .clear, in: Capsule())
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }.padding(5).clearGlass(30)
    }
}

@main struct LingjingApp: App {
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lens = LensModel()
    @StateObject private var screen = ScreenModel()
    @StateObject private var voice = VoiceModel()
    @State private var tab = 0
    @State private var settings = false
    @State private var showShortcutImage = false
    @State private var readingShortcutImage = false
    @State private var showInitialLanguages = false
    @State private var didApplyInitialLanguages = false
    private let importTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let voiceTicker = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

    init() {
        LingjingShortcuts.updateAppShortcutParameters()
        // Existing installations have already been set up; don't interrupt them.
        if UserDefaults.standard.bool(forKey: "nativeThemeDefault20261101"),
           UserDefaults.standard.object(forKey: "initialLanguageSetupComplete") == nil {
            UserDefaults.standard.set(true, forKey: "initialLanguageSetupComplete")
        }
        if !UserDefaults.standard.bool(forKey: "nativeThemeDefault20261101") {
            UserDefaults.standard.set(4, forKey: "qingyiVisualTheme")
            UserDefaults.standard.set(true, forKey: "nativeThemeDefault20261101")
        }
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            for name in ["app.state", "group.state", "group-write.state"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        if let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup) {
            for name in ["diagnostics.state", "group.state"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ZStack {
                    GlassWallpaper()
                    VStack(spacing: 0) {
                        if visualTheme == 2 {
                            ThemeThreeTabs(selection: $tab).padding(.horizontal, 20).padding(.vertical, 12)
                        } else if visualTheme == 1 {
                            Text(["屏幕翻译", "智能镜头", "语音翻译"][tab])
                                .font(.system(size: 21, weight: .medium, design: .rounded))
                                .foregroundStyle(.white).padding(.top, 8).padding(.bottom, 20)
                            GlassTabBar(selection: $tab).padding(.horizontal, 20).padding(.bottom, 14)
                        }
                        Group {
                            switch tab {
                            case 1: LensHome(model: lens)
                            case 2: VoiceHome(model: voice)
                            default: ScreenHome(model: screen, lens: lens)
                            }
                        }.animation(nil, value: tab)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if visualTheme == 5 {
                        MistTabBar(selection: $tab) { settings = true }
                            .padding(.horizontal, 18).padding(.bottom, 2)
                    } else if visualTheme == 4 {
                        NativeThemeTabs(selection: $tab).padding(.horizontal, 50).padding(.bottom, 6)
                    } else if visualTheme == 3 {
                        ThemeFourTabs(selection: $tab).padding(.horizontal, 24).padding(.bottom, 6)
                    } else if visualTheme == 0 {
                        GlassTabBar(selection: $tab)
                            .padding(.horizontal, 18).padding(.bottom, 4)
                    }
                }
                .font(visualTheme == 4 || visualTheme == 5 ? .body : .custom("AvenirNext-Regular", size: 17, relativeTo: .body))
                .tint(visualTheme == 1 ? Color(red: 1, green: 0.56, blue: 0.48) : (visualTheme == 5 ? Mist.ink : .blue))
                .toolbar(visualTheme == 5 ? .hidden : .automatic, for: .navigationBar)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { settings = true } label: {
                            Image(systemName: visualTheme == 4 ? "ellipsis" : "gearshape")
                                .accessibilityLabel("设置")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                        }.buttonStyle(.plain)
                    }
                }
                .sheet(isPresented: $settings) { SettingsView(voice: voice, lens: lens) }
                .onAppear {
                    voice.load()
                    guard !didApplyInitialLanguages else { return }
                    didApplyInitialLanguages = true
                    if let saved = UserDefaults.standard.string(forKey: "initialTargetLanguage"),
                       let language = AppLanguage(rawValue: saved), language != .auto {
                        screen.target = language; lens.target = language; voice.target = language
                    }
                    if let saved = UserDefaults.standard.string(forKey: "initialVoiceLanguage"),
                       let language = AppLanguage(rawValue: saved), language != .auto { voice.source = language }
                    showInitialLanguages = !UserDefaults.standard.bool(forKey: "initialLanguageSetupComplete")
                }
                .onReceive(importTicker) { _ in readShortcutImage() }
                .onReceive(NotificationCenter.default.publisher(for: .qingyiShortcutImageReady)) { _ in readShortcutImage() }
                .onReceive(voiceTicker) { _ in voice.tick() }
                .onChange(of: scenePhase) { _, value in if value == .active { readShortcutImage() } }
                .onOpenURL { url in if url.scheme == "qingyi" && url.host == "lens" { tab = 1 } }
                .fullScreenCover(isPresented: $showShortcutImage) { LensView(model: lens, onClose: { showShortcutImage = false }) }
                .sheet(isPresented: $showInitialLanguages) {
                    InitialLanguageSetup { source, target in
                        UserDefaults.standard.set(source.rawValue, forKey: "initialVoiceLanguage")
                        UserDefaults.standard.set(target.rawValue, forKey: "initialTargetLanguage")
                        UserDefaults.standard.set(true, forKey: "initialLanguageSetupComplete")
                        screen.target = target; lens.target = target
                        voice.source = source; voice.target = target
                        showInitialLanguages = false
                    }.interactiveDismissDisabled()
                }
            }
        }
    }

    private func readShortcutImage() {
        guard !readingShortcutImage,
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup) else { return }
        let url = folder.appendingPathComponent("shortcut-image")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        readingShortcutImage = true
        Task { @MainActor in
            defer { readingShortcutImage = false }
            // Read and decode off the main thread so the cover is not held up.
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                try? FileManager.default.removeItem(at: url)
                return UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data)
            }.value
            guard let image else { return }
            settings = false
            tab = 1
            lens.load(image)
            // Appear at once, without the slide-up animation.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { showShortcutImage = true }
            qyLog("shortcut image shown")
        }
    }
}

private struct InitialLanguageSetup: View {
    let finish: (AppLanguage, AppLanguage) -> Void
    @State private var source: AppLanguage = .english
    @State private var target: AppLanguage = .simplifiedChinese
    @State private var showPacks = false
    @State private var modelsReady = false
    @State private var requested = false
    @State private var requestedAt = Date.distantPast

    private func download() {
        guard !modelsReady else { return }
        requested = true
        requestedAt = Date()
        MLKitEngine.downloadModels([source.code, target.code])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("先选择常用的语言，之后可以在各功能中更改。屏幕翻译和智能镜头默认自动识别原文。")
                    Picker("常用原文语言", selection: $source) {
                        ForEach(AppLanguage.targets) { Text($0.rawValue).tag($0) }
                    }
                    Picker("翻译成", selection: $target) {
                        ForEach(AppLanguage.targets) { Text($0.rawValue).tag($0) }
                    }
                } header: { Text("选择语言") }
                Section {
                    Text("默认使用「更快 · 第三方离线翻译」。所选两种语言的离线模型每种约 30 MB，下载一次后完全离线使用，无需账号或付费。")
                    HStack {
                        Text("\(source.rawValue) / \(target.rawValue)")
                        Spacer()
                        if modelsReady {
                            Label("已就绪", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.subheadline)
                        } else if requested {
                            ProgressView().controlSize(.small)
                            Text("下载中…").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Button("下载") { download() }
                        }
                    }
                    NavigationLink("管理离线翻译模型") { MLKitModelsView() }
                } header: {
                    Text("离线翻译模型")
                } footer: {
                    Text("首次下载需要能访问谷歌下载服务器（国内网络可能需要开启代理）。也可以稍后在「设置 → 翻译」中下载；没下载完之前会自动改用苹果翻译。")
                }
                Section {
                    Button("开始使用") {
                        download()
                        finish(source, target)
                    }
                    .frame(maxWidth: .infinity)
                } footer: {
                    Text("想要更准确的苹果翻译，可在「设置 → 翻译」切换，并下载苹果语言包。")
                }
            }
            .navigationTitle("欢迎使用青译翻译")
            .mistSheet()
            .task(id: "\(source.rawValue)|\(target.rawValue)") {
                while !Task.isCancelled {
                    modelsReady = MLKitEngine.modelDownloaded(source.code) && MLKitEngine.modelDownloaded(target.code)
                    // A failed download (no access to the server) shows 下载 again.
                    if modelsReady || Date().timeIntervalSince(requestedAt) > 120 { requested = false }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .sheet(isPresented: $showPacks) { NavigationStack { LanguagePackView(source: source, target: target) } }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var voice: VoiceModel
    @ObservedObject var lens: LensModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @AppStorage("lensSelectionMenuDraggable") private var lensSelectionMenuDraggable = true
    @AppStorage("lensDragSnapsSentences") private var lensDragSnapsSentences = false
    @AppStorage("qingyiTranslationEngine") private var translationEngine = "fast"
    @AppStorage("lensAutoFitSnap") private var lensAutoFitSnap = true
    @AppStorage("lensZoomEnabled") private var lensZoomEnabled = true
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var wallpaperMessage = ""
    @ObservedObject private var wallpaper = WallpaperStore.shared
    @State private var deviceStatus = "点击重新检测，查看本机语言包、语音识别和画中画能力。"
    @State private var confirmClearSubtitles = false
    @State private var cacheMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                // 1. 翻译：三大功能共用的引擎与语言资源放在最前。
                Section {
                    Picker("翻译引擎", selection: $translationEngine) {
                        Label("更快 · 第三方离线翻译", systemImage: "hare").tag("fast")
                        Label("更准确 · 苹果翻译", systemImage: "checkmark.seal").tag("apple")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if translationEngine == "fast" {
                        NavigationLink { MLKitModelsView() } label: {
                            Label("离线快速翻译模型", systemImage: "arrow.down.circle")
                        }
                    }
                    NavigationLink { LanguagePackView() } label: {
                        Label("苹果翻译与语音语言包", systemImage: "globe")
                    }
                } header: {
                    Text("翻译")
                } footer: {
                    Text("所选引擎同时用于屏幕翻译、智能镜头和语音翻译。想要更快选第三方离线翻译（谷歌 ML Kit，免费、无需 API）；想要更准确选苹果翻译。第三方模型未下载的语言会自动改用苹果翻译。")
                }

                // 2. 外观
                Section {
                    Picker(selection: $visualTheme) {
                        Text("原生简洁").tag(4)
                        Text("雾面").tag(5)
                        Text("暖雾玻璃").tag(1)
                        Text("柔光").tag(2)
                        Text("彩趣").tag(3)
                        Text("清透玻璃").tag(0)
                    } label: {
                        Label("主题", systemImage: "paintpalette")
                    }
                    if visualTheme == 0 || visualTheme == 1 {
                        PhotosPicker(selection: $wallpaperItem, matching: .images) {
                            Label("选择背景图片", systemImage: "photo")
                        }
                        Button {
                            do { try wallpaper.reset(); wallpaperMessage = "已恢复默认壁纸" }
                            catch { wallpaperMessage = "恢复失败：\(error.localizedDescription)" }
                        } label: {
                            Label("恢复默认壁纸", systemImage: "arrow.counterclockwise")
                        }
                    }
                } header: {
                    Text("外观")
                } footer: {
                    Text(wallpaperMessage.isEmpty
                         ? (visualTheme == 0 || visualTheme == 1 ? "壁纸仅保存在这台设备上。" : "背景图片仅用于暖雾玻璃与清透玻璃主题。")
                         : wallpaperMessage)
                }

                // 3. 智能镜头
                Section {
                    Toggle(isOn: $lensZoomEnabled) { Label("双指缩放图片", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Toggle(isOn: $lensAutoFitSnap) { Label("接近全图时自动吸附", systemImage: "rectangle.dashed") }
                    Toggle(isOn: $lensSelectionMenuDraggable) { Label("可拖动选字菜单", systemImage: "hand.draw") }
                    Picker(selection: $lensDragSnapsSentences) {
                        Text("自由拖动").tag(false)
                        Text("按整句吸附").tag(true)
                    } label: {
                        Label("拖动选字", systemImage: "text.cursor")
                    }
                } header: {
                    Text("智能镜头")
                } footer: {
                    Text("点一下选一句，再点一下选整段；按住拖动可自由选择，开头没对准时会自动补齐。右上角分享按钮直接分享译图，「⋯」里可分享选中译文、复制、保存或切换原图。")
                }

                // 4. 语音翻译
                Section {
                    NavigationLink { VoiceStyleView(model: voice) } label: {
                        Label("字幕样式", systemImage: "captions.bubble")
                    }
                    Toggle(isOn: $voice.autoSave) { Label("自动保存字幕记录", systemImage: "tray.and.arrow.down") }
                    Button(role: .destructive) { confirmClearSubtitles = true } label: {
                        Label("清空字幕记录", systemImage: "trash")
                    }
                } header: {
                    Text("语音翻译")
                }

                // 5. 分享
                Section {
                    NavigationLink { ShareOrderSettingsView(image: lens.image) } label: {
                        Label("分享平台顺序", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("分享")
                }

                // 6. 隐私与存储
                Section {
                    Button(role: .destructive) {
                        if let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup) {
                            for name in ["frame.jpg", "ocr-frame.jpg", "shortcut-image"] {
                                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                            }
                        }
                        cacheMessage = "已清空临时屏幕画面"
                    } label: {
                        Label("清空临时屏幕画面", systemImage: "photo.badge.minus")
                    }
                    NavigationLink {
                        Form {
                            Section { Text(deviceStatus).font(.footnote) }
                            Section { Button("重新检测") { Task { await checkDevice() } } }
                        }
                        .navigationTitle("设备检测")
                    } label: {
                        Label("设备检测", systemImage: "iphone.gen3")
                    }
                } header: {
                    Text("隐私与存储")
                } footer: {
                    Text(cacheMessage.isEmpty
                         ? "文字识别与翻译都在本机完成，屏幕画面与声音不会上传。受保护的内容可能无法采集；画中画取决于系统支持。"
                         : cacheMessage)
                }
            }
            // Settings uses the system grouped style in every theme so section
            // headers and footers stay readable over dark wallpapers.
            .onChange(of: wallpaperItem) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw NSError(domain: "Wallpaper", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取图片"]) }
                        try wallpaper.set(data: data)
                        wallpaperMessage = "壁纸已更新"
                    } catch { wallpaperMessage = "壁纸设置失败：\(error.localizedDescription)" }
                    wallpaperItem = nil
                }
            }
            .navigationTitle("设置")
            .mistSheet()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .confirmationDialog("清空全部字幕记录？", isPresented: $confirmClearSubtitles, titleVisibility: .visible) {
                Button("清空", role: .destructive) { voice.clear() }
            } message: {
                Text("清空后无法恢复。")
            }
        }
    }

    private func checkDevice() async {
        let report = await DeviceDiagnostics.run()
        let language = report.languages.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "、")
        deviceStatus = "iOS \(report.systemVersion) · PiP \(report.pictureInPictureSupported ? "支持" : "不支持") · \(language)"
    }
}

struct ShareOrderSettingsView: View {
    let image: UIImage?
    @State private var showingShareSheet = false

    var body: some View {
        Form {
            Section("操作顺序") {
                Text("1. 打开智能镜头中的图片，轻点右上角的分享按钮。")
                Text("2. 在分享 App 那一排向左滑到末尾，轻点“更多”→“编辑”。")
                Text("3. 将常用平台加入“个人收藏”，再拖动排序。完成后返回青译即可使用。")
            }
            Section("打开系统分享设置") {
                Button("用最近导入的图片打开分享面板") { showingShareSheet = image != nil }
                    .disabled(image == nil)
                if image == nil {
                    Text("先在智能镜头导入一张图片，此处即可打开青译的分享面板。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("可用目标由已安装 App 的分享扩展和 iOS 决定。青译无法代替系统直接调整第三方 App 的顺序。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        .background(GlassWallpaper())
        .navigationTitle("分享平台顺序")
        .sheet(isPresented: $showingShareSheet) {
            if let image { ImageShareSheet(image: image) }
        }
    }
}

struct LanguageDeletionHelpView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section("删除系统翻译语言包") {
                Text("1. 打开 iPhone 设置。")
                Text("2. 进入「App」→「翻译」→「已下载的语言」。")
                Text("3. 在系统列表中删除不再需要的语言。")
                Button("打开青译的系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Text("按钮打开青译的设置页；请返回设置主列表，再按上面的路径操作。若找不到「翻译」，请确认已安装苹果的翻译 App。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("翻译语言包由 iOS 管理，并可能被其他 App 共用。青译无法直接删除系统资源；删除后回到青译，语言包状态会重新检查。语音识别资源另由系统管理。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        .background(GlassWallpaper())
        .navigationTitle("删除语言包")
    }
}

/// Settings page for Apple's translation and speech resources, laid out like
/// 离线快速翻译模型: one row per language with its status and a 下载 / 删除
/// button. Apple's packs are pair based, so each row reports
/// 「该语言 → 目标语言」. iOS owns the packs: downloading goes through the
/// system sheet, and deleting can only be done in iOS 设置.
struct LanguagePackView: View {
    @State private var target: AppLanguage = .simplifiedChinese
    @State private var focus: AppLanguage?
    @State private var status: [AppLanguage: LanguageAvailability.Status] = [:]
    @State private var downloading: AppLanguage?
    @State private var messages: [AppLanguage: String] = [:]
    @State private var config: TranslationSession.Configuration?
    @State private var requested: AppLanguage = .english
    @State private var deleting: AppLanguage?
    @State private var refreshToken = 0
    @State private var speech: [AppLanguage: Bool] = [:]
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    init(source: AppLanguage = .english, target: AppLanguage = .simplifiedChinese) {
        _target = State(initialValue: target == .auto ? .simplifiedChinese : target)
        _focus = State(initialValue: source == .auto || source == target ? nil : source)
    }

    private var rows: [AppLanguage] {
        let others = AppLanguage.targets.filter { $0 != target }
        guard let focus, let index = others.firstIndex(of: focus) else { return others }
        var sorted = others
        sorted.remove(at: index)
        return [focus] + sorted
    }

    var body: some View {
        Form {
            Section {
                Text("选择「更准确 · 苹果翻译」时使用这里的系统语言包。下载后完全离线翻译，也供语音翻译使用。")
                Text("语言包由 iOS 下载和管理，每种语言约 50–100 MB，可能与系统「翻译」App 共用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("翻译成", selection: $target) {
                    ForEach(AppLanguage.targets) { Text($0.rawValue).tag($0) }
                }
            } footer: {
                Text("苹果语言包按「原文 → 目标语言」成对检查；下载任意一行会一并准备目标语言。")
            }
            Section("语言包") {
                ForEach(rows) { language in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(language.rawValue)
                            Text(statusLine(language)).font(.caption).foregroundStyle(.secondary)
                            Text(speechLine(language)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if downloading == language {
                            ProgressView().controlSize(.small)
                        } else {
                            switch status[language] {
                            case .installed?:
                                Button("删除", role: .destructive) { deleting = language }
                                    .buttonStyle(.borderless)
                            case .supported?:
                                Button("下载") { download(language) }
                                    .buttonStyle(.borderless)
                                    .disabled(downloading != nil)
                            case nil:
                                ProgressView().controlSize(.mini)
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("苹果翻译与语音语言包")
        .mistSheet()
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除苹果语言包", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(deleting?.rawValue ?? "该语言")语言包由 iOS 统一管理，App 无法直接删除。请在 iPhone「设置」→「App」→「翻译」→「已下载的语言」中左滑删除；回到青译后状态会自动更新。")
        }
        .translationTask(config) { session in
            let language = requested
            do {
                try await session.prepareTranslation()
                messages[language] = nil
            } catch {
                messages[language] = "下载未完成：\(error.localizedDescription)"
            }
            downloading = nil
            await refresh()
            NotificationCenter.default.post(name: .init("QingyiLanguagePacksChanged"), object: nil)
        }
        .task(id: target) { await refresh() }
        .task(id: downloading) {
            // The system sheet finishes in the background; keep the row fresh.
            while downloading != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
            }
        }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await refresh() } }
        }
    }

    private func statusLine(_ language: AppLanguage) -> String {
        if let message = messages[language] { return message }
        if downloading == language { return "正在下载，请在系统面板中确认…" }
        switch status[language] {
        case .installed?: return "已下载，可离线翻译成\(target.rawValue)"
        case .supported?: return "未下载"
        case .unsupported?: return "苹果翻译暂不支持译成\(target.rawValue)"
        case nil: return "检查中…"
        default: return "状态未知"
        }
    }

    private func speechLine(_ language: AppLanguage) -> String {
        guard let available = speech[language] else { return "语音识别：检查中…" }
        return available ? "语音识别：本机可用" : "语音识别：本机暂不可用（由 iOS 自动下载）"
    }

    private func download(_ language: AppLanguage) {
        #if targetEnvironment(simulator)
        messages[language] = "苹果翻译不支持模拟器，请在真机上下载"
        #else
        guard let sourceCode = language.code, let targetCode = target.code else { return }
        messages[language] = nil
        requested = language
        downloading = language
        let next = TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceCode),
            target: Locale.Language(identifier: targetCode))
        if config?.source == next.source && config?.target == next.target {
            config?.invalidate()
        } else {
            config = next
        }
        #endif
    }

    private func refresh() async {
        refreshToken += 1
        let token = refreshToken
        let selectedTarget = target
        guard let targetCode = selectedTarget.code else { return }
        let checker = LanguageAvailability()
        var snapshot: [AppLanguage: LanguageAvailability.Status] = [:]
        for language in AppLanguage.targets where language != selectedTarget {
            guard let code = language.code else { continue }
            snapshot[language] = await checker.status(from: Locale.Language(identifier: code),
                                                       to: Locale.Language(identifier: targetCode))
            guard token == refreshToken, selectedTarget == target else { return }
        }
        status = snapshot
        if speech.isEmpty {
            for language in AppLanguage.targets {
                speech[language] = SFSpeechRecognizer(locale: Locale(identifier: language.speechLocale))?
                    .supportsOnDeviceRecognition == true
            }
        }
        if let current = downloading, snapshot[current] == .installed {
            downloading = nil
            NotificationCenter.default.post(name: .init("QingyiLanguagePacksChanged"), object: nil)
        }
    }
}

struct TranslationReadinessView: View {
    let source: AppLanguage
    let target: AppLanguage
    var speech = false
    @State private var status = "正在检查语言包…"
    @State private var showPacks = false
    @State private var showModels = false
    var body: some View {
        Button { if MLKitEngine.preferFast { showModels = true } else { showPacks = true } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(status, systemImage: "arrow.down.circle")
                if speech {
                    let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: source.speechLocale))
                    Text(speechRecognizer?.supportsOnDeviceRecognition == true
                         ? "本机语音识别可用"
                         : (speechRecognizer?.isAvailable == true ? "在线语音识别可用（未下载本机模型）" : "当前语种语音识别暂不可用"))
                }
            }.font(.caption)
        }
        .sheet(isPresented: $showPacks) {
            NavigationStack { LanguagePackView(source: source, target: target) }
        }
        .sheet(isPresented: $showModels) {
            NavigationStack { MLKitModelsView() }
        }
        .task(id: "\(source.rawValue)|\(target.rawValue)") {
            while !Task.isCancelled {
                if MLKitEngine.preferFast {
                    // Default engine: report the offline models, not Apple's packs.
                    let from = source == .auto ? "en" : (source.code ?? "en")
                    let ready = MLKitEngine.modelDownloaded(from) && MLKitEngine.modelDownloaded(target.code)
                    let label = source == .auto ? "自动识别 → \(target.rawValue)" : "\(source.rawValue) → \(target.rawValue)"
                    status = ready ? "\(label) · 离线快速翻译已就绪" : "\(label) · 离线模型未下载，点此下载"
                } else if source == .auto {
                    status = "自动识别 → \(target.rawValue) · 查看各语言包状态"
                } else if source == target {
                    status = "原文与译文语言相同"
                } else {
                    let state = await LanguageAvailability().status(
                        from: Locale.Language(identifier: source.code!),
                        to: Locale.Language(identifier: target.code!))
                    guard !Task.isCancelled else { return }
                    switch state {
                    case .installed: status = "\(source.rawValue) → \(target.rawValue) · ✓ 已下载"
                    case .supported: status = "\(source.rawValue) → \(target.rawValue) · 需下载，点此准备"
                    case .unsupported: status = "这组语言暂不支持"
                    @unknown default: status = "语言包状态未知"
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct ThemeThreeTabs: View {
    @Binding var selection: Int
    private let labels = ["屏幕翻译", "智能镜头", "语音翻译"]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(labels.indices, id: \.self) { index in
                Button { selection = index } label: {
                    Text(labels[index]).font(.system(size: 14, weight: selection == index ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundStyle(selection == index ? Color(uiColor: .systemBackground) : Color.primary.opacity(0.65))
                        .background(selection == index ? Color.primary : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }
    }
}
struct ThemeThreeCard: ViewModifier {
    var tinted = false
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(tinted ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.82, green: 0.68, blue: 0.75), Color(red: 0.68, green: 0.73, blue: 0.65), Color(red: 0.53, green: 0.67, blue: 0.53)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)))
        }
    }
}
extension View { func themeThreeCard(_ tinted: Bool = false) -> some View { modifier(ThemeThreeCard(tinted: tinted)) } }

struct ThemeFourTabs: View {
    @Binding var selection: Int
    private let labels = ["屏幕", "镜头", "语音"]
    private let icons = ["text.viewfinder", "viewfinder", "waveform"]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(labels.indices, id: \.self) { index in
                Button { selection = index } label: {
                    HStack(spacing: 7) { Image(systemName: icons[index]); Text(labels[index]).font(.caption.weight(.semibold)) }
                        .foregroundStyle(selection == index ? .black : .white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(selection == index ? Color(red: 0.87, green: 0.58, blue: 0.92) : Color.white.opacity(0.12), in: Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }.padding(5).background(.black, in: Capsule())
    }
}
struct ThemeFourCard: ViewModifier {
    var color: Color
    func body(content: Content) -> some View {
        content.background(color, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
extension View { func themeFourCard(_ color: Color = Color(uiColor: .secondarySystemGroupedBackground)) -> some View { modifier(ThemeFourCard(color: color)) } }

struct NativeThemeTabs: View {
    @Binding var selection: Int
    private let titles = ["屏幕翻译", "智能镜头", "语音翻译"]
    private let icons = ["text.viewfinder", "viewfinder", "waveform"]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { index in
                Button { selection = index } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icons[index]).font(.system(size: 20, weight: .semibold))
                        Text(titles[index]).font(.caption2)
                    }
                    .foregroundStyle(selection == index ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(selection == index ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }
        .padding(4)
        // iOS 26 style floating glass tab bar.
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
extension View {
    func nativeThemeCard() -> some View { background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous)) }
}

@MainActor final class InstalledLanguageOptions: ObservableObject {
    @Published private(set) var sources: Set<AppLanguage> = []
    @Published private(set) var targets: Set<AppLanguage> = []
    @Published private(set) var checking = true
    private var revision = 0
    func refresh(source: AppLanguage, target: AppLanguage, speech: Bool = false) async {
        revision += 1
        let current = revision
        checking = true
        sources = []
        targets = []
        let availability = LanguageAvailability()
        var installed: Set<AppLanguage> = []
        // Translation availability is a pair property. A language appears in
        // both pickers when any installed pair includes it; the selected pair
        // is checked separately by TranslationReadinessView.
        if MLKitEngine.preferFast {
            for lang in AppLanguage.targets where MLKitEngine.modelDownloaded(lang.code) {
                installed.insert(lang)
            }
        }
        for fromLanguage in AppLanguage.targets {
            guard let from = fromLanguage.code else { continue }
            for toLanguage in AppLanguage.targets where fromLanguage != toLanguage {
                guard !Task.isCancelled else { return }
                if installed.contains(fromLanguage) && installed.contains(toLanguage) { continue }
                guard let to = toLanguage.code else { continue }
                let status = await availability.status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
                if status == .installed { installed.insert(fromLanguage); installed.insert(toLanguage) }
            }
        }
        guard current == revision, !Task.isCancelled else { return }
        sources = installed
        targets = installed
        checking = false
    }
    func sourceOptions(current: AppLanguage, auto: Bool) -> [AppLanguage] {
        (auto ? [.auto] : []) + AppLanguage.targets.filter { sources.contains($0) || $0 == current }
    }
    func targetOptions(current: AppLanguage) -> [AppLanguage] { AppLanguage.targets.filter { targets.contains($0) || $0 == current } }
    func sourceLabel(_ language: AppLanguage) -> String { language == .auto || sources.contains(language) ? language.rawValue : "\(language.rawValue)（不可用）" }
    func targetLabel(_ language: AppLanguage) -> String { targets.contains(language) ? language.rawValue : "\(language.rawValue)（不可用）" }
}
