import AppIntents
import UniformTypeIdentifiers
import Foundation

struct ImportImageIntent: AppIntent {
    static var title: LocalizedStringResource = "用青译识别图片"
    static var description = IntentDescription("接收快捷指令中的截图或图片，打开智能镜头识别和翻译。")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "图片") var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("用青译识别 \(\.$image)")
    }

    func perform() async throws -> some IntentResult {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup) else {
            throw ImportError.containerUnavailable
        }
        let data = try await image.withFile(contentType: .image) { url, _ in
            try Data(contentsOf: url)
        }
        try data.write(to: folder.appendingPathComponent("shortcut-image"), options: .atomic)
        // The intent runs inside the app: tell it right away instead of
        // waiting for the next poll (that wait was most of the delay).
        await MainActor.run {
            NotificationCenter.default.post(name: .qingyiShortcutImageReady, object: nil)
        }
        return .result()
    }
}

struct LingjingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ImportImageIntent(),
                    phrases: ["用\(.applicationName)识别图片", "使用\(.applicationName)智能镜头"],
                    shortTitle: "智能镜头",
                    systemImageName: "viewfinder")
    }
}

extension Notification.Name {
    static let qingyiShortcutImageReady = Notification.Name("QingyiShortcutImageReady")
}

enum ImportError: LocalizedError {
    case containerUnavailable
    var errorDescription: String? { "无法访问本机共享容器，请检查 App Group 签名。" }
}
