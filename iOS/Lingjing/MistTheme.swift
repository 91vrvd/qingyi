import SwiftUI

// 「雾面」theme (visualTheme == 5): a misty blue-grey frosted background,
// hairline type, soft squircle chips and one large porcelain card per page
// with an arc dial that shows where the user is in the flow.

enum Mist {
    static let ink = Color(red: 0.14, green: 0.15, blue: 0.17)
    static let inkSoft = Color(red: 0.52, green: 0.55, blue: 0.60)
    static let porcelain = Color(red: 0.965, green: 0.97, blue: 0.978)
    static let glassFill = Color.white.opacity(0.16)
    static let glassStroke = Color.white.opacity(0.42)

    static func thin(_ size: CGFloat) -> Font { .system(size: size, weight: .ultraLight) }
    static func light(_ size: CGFloat) -> Font { .system(size: size, weight: .light) }
}

extension AppLanguage {
    /// Short label for the large hairline numerals on 雾面 cards.
    var mistCode: String {
        switch self {
        case .auto: "Auto"
        case .simplifiedChinese: "中"
        default: (code ?? "").prefix(2).uppercased()
        }
    }
}

/// Smooth misty gradient with two soft light pools, like frosted glass.
struct MistBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.47, green: 0.53, blue: 0.62),
                                        Color(red: 0.62, green: 0.69, blue: 0.79),
                                        Color(red: 0.74, green: 0.80, blue: 0.88),
                                        Color(red: 0.66, green: 0.72, blue: 0.81)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.white.opacity(0.42), .clear],
                               center: .init(x: 0.82, y: 0.18), startRadius: 0,
                               endRadius: geometry.size.width * 0.75)
                RadialGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.53).opacity(0.35), .clear],
                               center: .init(x: 0.05, y: 0.92), startRadius: 0,
                               endRadius: geometry.size.width * 0.9)
                RadialGradient(colors: [Color(red: 0.86, green: 0.82, blue: 0.86).opacity(0.25), .clear],
                               center: .init(x: 0.15, y: 0.05), startRadius: 0,
                               endRadius: geometry.size.width * 0.6)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Frosted squircle surface with a hairline highlight.
struct MistGlass: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Mist.glassFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Mist.glassStroke, Color.white.opacity(0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 0.8))
            .shadow(color: Color(red: 0.25, green: 0.30, blue: 0.40).opacity(0.12), radius: 14, y: 8)
    }
}

extension View {
    func mistGlass(_ radius: CGFloat = 26) -> some View { modifier(MistGlass(radius: radius)) }

    /// The large porcelain card that carries each page's content.
    func mistCard() -> some View {
        self
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.97), Mist.porcelain],
                                         startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: Color(red: 0.22, green: 0.27, blue: 0.36).opacity(0.16), radius: 30, y: 16)
            .foregroundStyle(Mist.ink)
    }
}

/// Round frosted button with a hairline icon.
struct MistCircleButton: View {
    let systemImage: String
    var size: CGFloat = 46
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size > 50 ? 18 : 16, weight: .light))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Mist.glassFill, in: Circle())
        .overlay(Circle().strokeBorder(Mist.glassStroke, lineWidth: 0.8))
        .accessibilityLabel(label)
    }
}

/// Top bar: frosted circle · light italic title · frosted circle.
struct MistTopBar<Left: View, Right: View>: View {
    let title: String
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right
    var body: some View {
        HStack {
            left()
            Spacer()
            Text(title).font(.system(size: 20, weight: .light)).italic()
                .foregroundStyle(.white)
                .tracking(0.3)
            Spacer()
            right()
        }
        .padding(.top, 2)
    }
}

/// Squircle chip: frosted when idle, solid porcelain when selected.
struct MistChip: View {
    let systemImage: String
    let title: String
    var selected = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { MistChipLabel(systemImage: systemImage, title: title, selected: selected) }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.55 : 1)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MistChipLabel: View {
    let systemImage: String
    let title: String
    var selected = false
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 19, weight: selected ? .regular : .light))
            Text(title).font(.system(size: 13, weight: .light)).italic().lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(selected ? Mist.ink : .white)
        .frame(width: 78, height: 92)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.white.opacity(0.96))
                    .shadow(color: Color(red: 0.2, green: 0.26, blue: 0.36).opacity(0.18), radius: 12, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Mist.glassFill)
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(Mist.glassStroke.opacity(0.8), lineWidth: 0.7))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
    }
}

/// Card header: light title and a thin ↗ action.
struct MistCardHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)?
    var body: some View {
        HStack {
            Text(title).font(.system(size: 18, weight: .light)).italic()
            Spacer()
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        if let actionTitle { Text(actionTitle).font(.system(size: 13, weight: .light)) }
                        Image(systemName: "arrow.up.right").font(.system(size: 15, weight: .light))
                    }
                    .foregroundStyle(Mist.ink)
                    .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Hairline numerals with a small suffix, e.g. 「EN → 中文」.
struct MistBigValue: View {
    let value: String
    let suffix: String
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(value).font(Mist.thin(54)).lineLimit(1).minimumScaleFactor(0.5)
            Text(suffix).font(Mist.thin(21)).foregroundStyle(Mist.inkSoft).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// Small pie dot plus value, used for the two stats beside the numerals.
struct MistStat: View {
    let fraction: Double
    let text: String
    var dim = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Mist.ink.opacity(dim ? 0.08 : 0.12))
                Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                    .fill(Mist.ink.opacity(dim ? 0.25 : 0.88))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            Text(text).font(Mist.light(16)).monospacedDigit().lineLimit(1)
        }
    }
}

/// Arc dial: hairline arc with labelled stops, a knob at the current step and
/// activity ticks above it (live activity while something is running).
struct MistArcGauge: View, Equatable {
    let labels: [String]
    /// 0…1 along the arc.
    let progress: Double
    /// Live when true: the ticks breathe; otherwise they rest low.
    var active = false
    /// 0…1 extra amplitude for the ticks (e.g. voice level).
    var level: Double = 0.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, time: active ? time : 0)
            }
        }
        .frame(height: 112)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        // A flat, wide arc so the dial stays compact in height.
        let radius = size.width * 1.35
        let apex: CGFloat = 40
        let center = CGPoint(x: size.width / 2, y: apex + radius)
        let half = asin(min(0.98, (size.width / 2 + 6) / radius))
        func point(_ angle: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: center.x + r * CGFloat(sin(angle)), y: center.y - r * CGFloat(cos(angle)))
        }
        func angle(at fraction: Double) -> Double { -half + 2 * half * fraction }
        let knobAngle = angle(at: max(0, min(1, progress)))

        // Guide arc (dashed) far above, like a scale.
        var guide = Path()
        guide.addArc(center: center, radius: radius + apex - 4, startAngle: .radians(-.pi / 2 - half),
                     endAngle: .radians(-.pi / 2 + half), clockwise: false)
        context.stroke(guide, with: .color(Mist.ink.opacity(0.12)), style: StrokeStyle(lineWidth: 0.8, dash: [6, 7]))

        // Activity ticks.
        let count = 44
        for index in 0..<count {
            let fraction = Double(index) / Double(count - 1)
            let a = angle(at: fraction)
            let wave = active
                ? (0.5 + 0.5 * sin(time * 3.1 + Double(index) * 0.55)) * (0.5 + 0.5 * sin(time * 1.7 - Double(index) * 0.23))
                : 0.12
            let behind = a <= knobAngle
            let length = 4 + CGFloat((behind ? 1 : 0.35) * wave * (8 + 18 * level))
            var tick = Path()
            tick.move(to: point(a, radius + 8))
            tick.addLine(to: point(a, radius + 8 + length))
            context.stroke(tick, with: .color(Mist.ink.opacity(behind ? 0.75 : 0.22)),
                           lineWidth: index % 4 == 0 ? 1.4 : 0.8)
        }

        // Main arc: solid up to the knob, faint after it.
        var done = Path()
        done.addArc(center: center, radius: radius, startAngle: .radians(-.pi / 2 - half),
                    endAngle: .radians(-.pi / 2 + knobAngle), clockwise: false)
        context.stroke(done, with: .color(Mist.ink), lineWidth: 1.4)
        var rest = Path()
        rest.addArc(center: center, radius: radius, startAngle: .radians(-.pi / 2 + knobAngle),
                    endAngle: .radians(-.pi / 2 + half), clockwise: false)
        context.stroke(rest, with: .color(Mist.ink.opacity(0.22)), lineWidth: 1.4)
        var inner = Path()
        inner.addArc(center: center, radius: radius - 9, startAngle: .radians(-.pi / 2 - half),
                     endAngle: .radians(-.pi / 2 + half), clockwise: false)
        context.stroke(inner, with: .color(Mist.ink.opacity(0.07)), lineWidth: 7)

        // Stops with labels written along the arc.
        for (index, label) in labels.enumerated() {
            let fraction = labels.count == 1 ? 0.5 : (Double(index) + 0.5) / Double(labels.count)
            let a = angle(at: fraction)
            var mark = Path()
            mark.move(to: point(a, radius - 4))
            mark.addLine(to: point(a, radius - 11))
            context.stroke(mark, with: .color(Mist.ink.opacity(0.35)), lineWidth: 1)
            let position = point(a, radius - 22)
            var layer = context
            layer.translateBy(x: position.x, y: position.y)
            layer.rotate(by: .radians(a))
            let reached = a <= knobAngle + 0.001
            layer.draw(Text(label).font(.system(size: 11, weight: reached ? .regular : .light))
                .foregroundColor(Mist.ink.opacity(reached ? 0.85 : 0.4)), at: .zero)
        }

        // Knob.
        let knob = point(knobAngle, radius)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.18), radius: 5, y: 2))
            layer.fill(Path(ellipseIn: CGRect(x: knob.x - 11, y: knob.y - 11, width: 22, height: 22)),
                       with: .color(.white))
        }
        context.fill(Path(ellipseIn: CGRect(x: knob.x - 3.5, y: knob.y - 3.5, width: 7, height: 7)),
                     with: .color(Mist.ink))
    }
}

/// Dark pill used for the one main action on a 雾面 card.
struct MistPrimaryButton: View {
    let title: String
    let systemImage: String
    var quiet = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { MistPrimaryLabel(title: title, systemImage: systemImage, quiet: quiet) }
            .buttonStyle(.plain)
    }
}

struct MistPrimaryLabel: View {
    let title: String
    let systemImage: String
    var quiet = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .regular))
            Text(title).font(.system(size: 17, weight: .regular)).tracking(0.5)
        }
        .foregroundStyle(quiet ? Mist.ink : .white)
        .frame(maxWidth: .infinity).frame(height: 52)
        .background(quiet ? AnyShapeStyle(Mist.ink.opacity(0.06)) : AnyShapeStyle(Mist.ink),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(Mist.ink.opacity(quiet ? 0.12 : 0), lineWidth: 0.8))
        .contentShape(Capsule())
    }
}

/// Language capsule inside a card: 「原文 · 英语」.
struct MistMenuLabel: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .light)).foregroundStyle(Mist.inkSoft)
            HStack(spacing: 4) {
                Text(value).font(Mist.light(16)).lineLimit(1).minimumScaleFactor(0.75)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .light)).foregroundStyle(Mist.inkSoft)
            }
        }
        .foregroundStyle(Mist.ink)
        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(Mist.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Centered insight text under the arc.
struct MistInsight: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 19, weight: .regular)).tracking(0.3)
            Text(detail).font(Mist.light(14)).foregroundStyle(Mist.inkSoft)
                .lineLimit(2, reservesSpace: true).minimumScaleFactor(0.85)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: title)
    }
}

/// Bottom navigation: frosted capsule with a porcelain selected pill, plus a
/// separate frosted circle for settings.
struct MistTabBar: View {
    @Binding var selection: Int
    var onSettings: () -> Void
    /// The pill moves at once; the page switch follows a moment later so
    /// building the new page does not stall the pill animation.
    @State private var shown: Int?
    private let items = [("屏幕", "rectangle.on.rectangle"), ("镜头", "viewfinder"), ("语音", "waveform")]
    var body: some View {
        let current = shown ?? selection
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    let selected = index == current
                    Button {
                        guard index != current else { return }
                        shown = index
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            selection = index
                            shown = nil
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: items[index].1).font(.system(size: 18, weight: selected ? .regular : .light))
                            Text(items[index].0).font(.system(size: 12, weight: .light)).italic()
                        }
                        .foregroundStyle(selected ? Mist.ink : .white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .background(alignment: .leading) {
                GeometryReader { geometry in
                    let width = (geometry.size.width - 8) / CGFloat(items.count)
                    RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.white.opacity(0.96))
                        .shadow(color: Color(red: 0.2, green: 0.26, blue: 0.36).opacity(0.2), radius: 10, y: 5)
                        .frame(width: width, height: geometry.size.height)
                        .offset(x: (width + 4) * CGFloat(current))
                        .animation(.snappy(duration: 0.28), value: current)
                }
            }
            .padding(5)
            .mistGlass(31)
            MistCircleButton(systemImage: "gearshape", size: 64, label: "设置", action: onSettings)
        }
    }
}

/// Horizontal capsule switch with a caption: the selected option is a
/// porcelain pill that slides inside a frosted track.
struct MistSegment<Value: Hashable>: View {
    let caption: String
    let options: [(value: Value, icon: String, title: String)]
    let selection: Value
    var disabled = false
    let onSelect: (Value) -> Void
    /// The pill slides immediately (cheap offset animation); the change is
    /// applied after it, so the page update does not cost animation frames.
    @State private var shown: Value?

    var body: some View {
        let current = shown ?? selection
        let index = options.firstIndex { $0.value == current } ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.system(size: 12, weight: .light)).italic()
                .foregroundStyle(.white.opacity(0.88)).padding(.leading, 14)
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { position in
                    let option = options[position]
                    let selected = position == index
                    Button {
                        guard option.value != current else { return }
                        shown = option.value
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                            onSelect(option.value)
                            shown = nil
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.icon).font(.system(size: 14, weight: selected ? .regular : .light))
                            Text(option.title).font(.system(size: 14, weight: selected ? .regular : .light))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(selected ? Mist.ink : .white)
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .background(alignment: .leading) {
                GeometryReader { geometry in
                    let width = geometry.size.width / CGFloat(max(1, options.count))
                    Capsule().fill(Color.white.opacity(0.96))
                        .shadow(color: Color(red: 0.2, green: 0.26, blue: 0.36).opacity(0.18), radius: 8, y: 4)
                        .frame(width: width, height: geometry.size.height)
                        .offset(x: width * CGFloat(index))
                        .animation(.snappy(duration: 0.26), value: index)
                }
            }
            .padding(4)
            .background(Mist.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Mist.glassStroke, lineWidth: 0.8))
            .opacity(disabled ? 0.55 : 1)
            .disabled(disabled)
        }
    }
}

/// Frosted capsule action: icon + short label.
struct MistCapsuleLabel: View {
    let systemImage: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .light))
            Text(title).font(.system(size: 14, weight: .light)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity).frame(height: 46)
        .background(Mist.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Mist.glassStroke, lineWidth: 0.8))
        .contentShape(Capsule())
    }
}

/// Sheet header in the 雾面 style: light italic title + frosted close button.
struct MistSheetHeader: View {
    let title: String
    var subtitle: String? = nil
    var onClose: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .light)).italic()
                if let subtitle {
                    Text(subtitle).font(Mist.light(14)).foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.white)
            Spacer()
            MistCircleButton(systemImage: "xmark", size: 40, label: "关闭", action: onClose)
        }
    }
}

/// Numbered porcelain list used by the 雾面 help sheets.
struct MistStepsCard: View {
    let steps: [(title: String, detail: String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)").font(.system(size: 13, weight: .regular)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Mist.ink, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        if !step.title.isEmpty { Text(step.title).font(.system(size: 16, weight: .regular)) }
                        Text(step.detail).font(Mist.light(14)).foregroundStyle(Mist.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                if index < steps.count - 1 { Divider().overlay(Mist.ink.opacity(0.06)).padding(.leading, 40) }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Mist.porcelain))
        .foregroundStyle(Mist.ink)
        .shadow(color: Color(red: 0.22, green: 0.27, blue: 0.36).opacity(0.14), radius: 20, y: 10)
    }
}

/// Simple sheet with numbered tips, shared by the 雾面 pages.
struct MistHelpSheet: View {
    let title: String
    let lines: [String]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MistSheetHeader(title: title) { dismiss() }
                MistStepsCard(steps: lines.map { (title: "", detail: $0) })
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
        .background(MistBackground())
        .environment(\.colorScheme, .light)
        .presentationDetents([.medium, .large])
        .presentationBackground { MistBackground() }
        .presentationCornerRadius(38)
    }
}

/// Applied to sheets and full-screen pages: in the 雾面 theme they get the
/// misty background, light type and ink accents; other themes are unchanged.
struct MistSheetStyle: ViewModifier {
    @AppStorage("qingyiVisualTheme") private var visualTheme = 4
    @ViewBuilder func body(content: Content) -> some View {
        if visualTheme == 5 {
            content
                .scrollContentBackground(.hidden)
                .background(MistBackground())
                .fontWeight(.light)
                .tint(Mist.ink)
                .environment(\.colorScheme, .light)
                .toolbarBackground(.hidden, for: .navigationBar)
                .presentationBackground { MistBackground() }
                .presentationCornerRadius(38)
        } else {
            content
        }
    }
}

extension View {
    func mistSheet() -> some View { modifier(MistSheetStyle()) }
}
