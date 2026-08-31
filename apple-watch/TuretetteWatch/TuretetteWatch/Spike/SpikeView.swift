import SwiftUI

/// G0 スパイクの計測画面。
///
/// 表示はすべて「計測結果を読むため」のもので、製品の UI ではない。
/// 手順は `docs/spike-g0.md` を参照。
struct SpikeView: View {

    @ObservedObject private var central = SpikeCentral.shared
    @State private var summary: String = ""
    @State private var events: [SpikeEvent] = []
    @State private var probing = false

    var body: some View {
        TabView {
            statusTab
            summaryTab
            logTab
        }
        .tabViewStyle(.page)
        .onAppear(perform: refresh)
    }

    // MARK: 状態

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("G0 スパイク")
                    .font(.headline)

                LabeledRow("BLE", central.stateText)
                LabeledRow("接続", central.isConnected ? "接続中" : "未接続")
                LabeledRow("最新 seq", "\(central.lastSeq)")
                LabeledRow("遅延", "\(central.lastLatencyMs) ms")

                Divider()

                Text("フェーズ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    phaseButton("A", help: "notify のみ")
                    phaseButton("B", help: "切断のみ")
                }

                Divider()

                Button {
                    probing = true
                    SpikeRunner.shared.probeNow { probing = false; refresh() }
                } label: {
                    Label(probing ? "計測中…" : "遡り問い合わせを 1 回",
                          systemImage: "figure.walk.motion")
                }
                .disabled(probing)

                Button {
                    SpikeCentral.shared.forceDisconnect()
                } label: {
                    Label("手動で切断", systemImage: "bolt.horizontal.circle")
                }

                Text(SpikeMotionProbe.shared.availabilityText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private func phaseButton(_ name: String, help: String) -> some View {
        Button {
            SpikeLog.shared.phase = name
            refresh()
        } label: {
            VStack(spacing: 1) {
                Text(name).font(.headline)
                Text(help).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
        }
        .tint(SpikeLog.shared.phase == name ? .accentColor : .gray)
    }

    // MARK: 集計

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary)
                    .font(.system(size: 12, design: .monospaced))

                Button {
                    refresh()
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }

                Button(role: .destructive) {
                    SpikeLog.shared.clear()
                    refresh()
                } label: {
                    Label("ログ消去", systemImage: "trash")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: ログ

    private var logTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("イベント \(events.count) 件（新しい順）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(visibleEvents, id: \.id) { event in
                    SpikeEventRow(event: event)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: 補助

    /// 新しい順に最大 120 件。型を明示しないと ForEach が Binding 版に解決されてしまう。
    private var visibleEvents: [SpikeEvent] {
        let newestFirst: [SpikeEvent] = events.reversed()
        return Array(newestFirst.prefix(120))
    }

    private func refresh() {
        summary = SpikeLog.shared.summaryText()
        events = SpikeLog.shared.events()
    }

}

/// ログ 1 行。`ForEach` の型推論を簡単にするため、本体から切り出している。
private struct SpikeEventRow: View {

    let event: SpikeEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(Self.time(event.at))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(event.kind.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.color(for: event.kind))
                Text(event.appState)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(event.appState == "active" ? Color.secondary : Color.orange)
            }
            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
        }
    }

    private static func time(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }

    private static func color(for kind: SpikeEvent.Kind) -> Color {
        switch kind {
        case .notify, .wake, .restore:      return .green
        case .budgetNear:                   return .yellow
        case .budgetExceeded, .probeLost:   return .red
        case .disconnect:                   return .orange
        case .probeStart, .probeEnd:        return .cyan
        default:                            return .secondary
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced))
        }
    }
}
