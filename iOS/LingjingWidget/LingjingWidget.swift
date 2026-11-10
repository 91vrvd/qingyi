import SwiftUI
import WidgetKit

struct LensEntry: TimelineEntry {
    let date: Date
}

struct LensProvider: TimelineProvider {
    func placeholder(in context: Context) -> LensEntry { LensEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (LensEntry) -> Void) {
        completion(LensEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LensEntry>) -> Void) {
        completion(Timeline(entries: [LensEntry(date: .now)], policy: .never))
    }
}

struct LensLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QingyiLens", provider: LensProvider()) { _ in
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.green)
                Spacer(minLength: 0)
                Text("智能镜头").font(.headline)
                Text("打开并导入截图").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(16)
            .containerBackground(Color(red: 0.91, green: 0.98, blue: 0.93), for: .widget)
            .widgetURL(URL(string: "qingyi://lens"))
        }
        .configurationDisplayName("青译智能镜头")
        .description("从主屏幕快速打开智能镜头；在快捷指令里可将截屏传给青译。")
        .supportedFamilies([.systemSmall])
    }
}

@main struct LingjingWidgetBundle: WidgetBundle {
    var body: some Widget { LensLauncherWidget() }
}
