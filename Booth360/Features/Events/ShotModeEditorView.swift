import SwiftUI

/// 分段节奏编辑器：本地草稿随操作即时回写，不需要额外保存。
struct ShotModeEditorView: View {
    @State private var draft: ShotMode
    private let onChange: (ShotMode) -> Void

    init(mode: ShotMode, onChange: @escaping (ShotMode) -> Void) {
        _draft = State(initialValue: mode)
        self.onChange = onChange
    }

    private var phaseIndices: Range<Int> {
        0..<min(draft.phaseDurations.count, min(draft.phaseRates.count, draft.phaseTitles.count))
    }

    private var phases: [ShotModeTimelinePhase] {
        phaseIndices.map { index in
            ShotModeTimelinePhase(
                id: index,
                title: draft.phaseTitles[index],
                recordingSeconds: draft.phaseDurations[index],
                rate: draft.phaseRates[index],
                color: phaseColor(at: index)
            )
        }
    }

    var body: some View {
        Form {
            summarySection
            recordingSection
            timelineSection

            ForEach(phaseIndices, id: \.self) { index in
                phaseSection(at: index)
            }

            resetSection
        }
        .navigationTitle("\(draft.kind.displayName) · 节奏")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft) { _, updated in
            onChange(updated)
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(draft.kind.displayName, systemImage: draft.kind.sfSymbol)
                    .font(.headline)
                Text("预计成片 \(seconds(draft.estimatedOutputSeconds)) 秒")
                    .font(.title2.weight(.semibold).monospacedDigit())
                Text("仅计算当前模式的变速片段，不含片头、片尾或循环。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private var recordingSection: some View {
        Section {
            ShotModeParameterSlider(
                title: "总录制时长",
                valueText: "\(draft.recordingSeconds) 秒",
                value: recordingBinding,
                range: Double(ShotModeKind.secondsRange.lowerBound)...Double(ShotModeKind.secondsRange.upperBound),
                step: 1,
                minimumText: "\(ShotModeKind.secondsRange.lowerBound) 秒",
                maximumText: "\(ShotModeKind.secondsRange.upperBound) 秒"
            )
        } footer: {
            Text("调整总时长时，各阶段会按当前比例缩放。")
        }
    }

    private var timelineSection: some View {
        Section {
            ShotModeTimelineView(
                title: "录制时间分配",
                phases: phases,
                usesOutputDuration: false
            )
            ShotModeTimelineView(
                title: "变速后的成片时间",
                phases: phases,
                usesOutputDuration: true
            )
        } header: {
            Text("节奏时间条")
        } footer: {
            Text("颜色与下方阶段对应。调整某一段时长，其余阶段按比例分配剩余录制时间。")
        }
    }

    private func phaseSection(at index: Int) -> some View {
        Section {
            ShotModeParameterSlider(
                title: "这一段录制时长",
                valueText: "\(seconds(draft.phaseDurations[index])) 秒",
                value: durationBinding(at: index),
                range: phaseDurationRange,
                step: 0.25,
                minimumText: "\(seconds(phaseDurationRange.lowerBound)) 秒",
                maximumText: "\(seconds(phaseDurationRange.upperBound)) 秒"
            )
            ShotModeParameterSlider(
                title: "播放倍速",
                valueText: "\(seconds(draft.phaseRates[index]))× · \(speedDescription(draft.phaseRates[index]))",
                value: rateBinding(at: index),
                range: ShotMode.phaseRateRange,
                step: 0.25,
                minimumText: "0.25× 慢镜",
                maximumText: "4× 加速"
            )
            LabeledContent(
                "这一段成片时长",
                value: "约 \(seconds(phases[index].outputSeconds)) 秒"
            )
            .font(.subheadline.monospacedDigit())
        } header: {
            HStack(spacing: 8) {
                Circle()
                    .fill(phaseColor(at: index))
                    .frame(width: 9, height: 9)
                Text("\(index + 1). \(draft.phaseTitles[index])")
            }
        } footer: {
            Text("录制第 \(seconds(phaseStart(at: index)))–\(seconds(phaseEnd(at: index))) 秒。倍速越小，画面越慢，成片越长。")
        }
    }

    private var resetSection: some View {
        Section {
            Button {
                draft.resetTiming()
            } label: {
                Label("恢复该模式默认节奏", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("恢复默认分段和倍速，保留总录制时长。调整会立即生效。")
        }
    }

    private var recordingBinding: Binding<Double> {
        Binding(
            get: { Double(draft.recordingSeconds) },
            set: { draft.recordingSeconds = Int($0.rounded()) }
        )
    }

    private var phaseDurationRange: ClosedRange<Double> {
        let minimum = ShotMode.minimumPhaseDuration
        let otherMinimum = Double(max(0, phaseIndices.count - 1)) * minimum
        return minimum...max(minimum, Double(draft.recordingSeconds) - otherMinimum)
    }

    private func durationBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { draft.phaseDurations[index] },
            set: { draft.setPhaseDuration($0, at: index) }
        )
    }

    private func rateBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { draft.phaseRates[index] },
            set: { draft.setPhaseRate($0, at: index) }
        )
    }

    private func phaseStart(at index: Int) -> Double {
        draft.phaseDurations.prefix(index).reduce(0, +)
    }

    private func phaseEnd(at index: Int) -> Double {
        phaseStart(at: index) + draft.phaseDurations[index]
    }

    private func phaseColor(at index: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .purple, .teal, .pink]
        return colors[index % colors.count]
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func speedDescription(_ rate: Double) -> String {
        if rate < 1 { return "慢镜" }
        if rate > 1 { return "加速" }
        return "原速"
    }
}

private struct ShotModeParameterSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let minimumText: String
    let maximumText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 10)
                Text(valueText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)

            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)

            HStack {
                Text(minimumText)
                Spacer()
                Text(maximumText)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private struct ShotModeTimelinePhase: Identifiable {
    let id: Int
    let title: String
    let recordingSeconds: Double
    let rate: Double
    let color: Color

    var outputSeconds: Double { recordingSeconds / max(rate, 0.25) }
}

/// 时间条仅展示当前参数的时长分配，不模拟未拍摄的视频画面。
private struct ShotModeTimelineView: View {
    let title: String
    let phases: [ShotModeTimelinePhase]
    let usesOutputDuration: Bool

    private var totalSeconds: Double {
        phases.reduce(0) { $0 + duration(of: $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(formatted(totalSeconds)) 秒")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(phases) { phase in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(phase.color)
                            .frame(width: segmentWidth(for: phase, availableWidth: geometry.size.width))
                            .overlay {
                                if segmentWidth(for: phase, availableWidth: geometry.size.width) >= 24 {
                                    Text("\(phase.id + 1)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                            }
                    }
                }
            }
            .frame(height: 30)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilitySummary)

            HStack {
                Text("0 秒")
                Spacer()
                Text("\(formatted(totalSeconds)) 秒")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var accessibilitySummary: String {
        phases.map { phase in
            "\(phase.title) \(formatted(duration(of: phase))) 秒"
        }.joined(separator: "，")
    }

    private func duration(of phase: ShotModeTimelinePhase) -> Double {
        usesOutputDuration ? phase.outputSeconds : phase.recordingSeconds
    }

    private func segmentWidth(for phase: ShotModeTimelinePhase, availableWidth: CGFloat) -> CGFloat {
        guard totalSeconds > 0 else { return 0 }
        let gaps = CGFloat(max(0, phases.count - 1)) * 2
        return max(0, availableWidth - gaps) * CGFloat(duration(of: phase) / totalSeconds)
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
