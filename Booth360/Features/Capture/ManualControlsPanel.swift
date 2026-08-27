import SwiftUI

/// 手动控制面板（Sheet）：曝光（ISO/快门/EV）、对焦、白平衡。
/// 每个滑杆改动即时下发到引擎；范围来自设备实际能力（engine.manualLimits）。
struct ManualControlsPanel: View {
    @Bindable var viewModel: CaptureViewModel

    private var limits: ManualControlLimits { viewModel.engine.manualLimits }

    var body: some View {
        NavigationStack {
            Form {
                exposureSection
                focusSection
                whiteBalanceSection
            }
            .navigationTitle("手动控制")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .onChange(of: viewModel.manualControls) { _, _ in
            viewModel.applyManualControls()
        }
    }

    // MARK: - 曝光

    private var exposureSection: some View {
        Section("曝光") {
            Toggle("锁定曝光（ISO + 快门）", isOn: Binding(
                get: { viewModel.manualControls.exposureLocked },
                set: { newValue in
                    if newValue { viewModel.willToggleLock(exposure: true) }
                    viewModel.manualControls.exposureLocked = newValue
                }
            ))

            if viewModel.manualControls.exposureLocked {
                LabeledSlider(
                    title: "ISO",
                    valueText: "\(Int(viewModel.manualControls.iso))",
                    value: $viewModel.manualControls.iso,
                    range: limits.minISO...limits.maxISO
                )
                Picker("快门", selection: $viewModel.manualControls.shutterSeconds) {
                    ForEach(ManualControlState.shutterChoices, id: \.self) { seconds in
                        Text(ManualControlState.shutterLabel(seconds)).tag(seconds)
                    }
                }
            } else {
                LabeledSlider(
                    title: "EV 偏移",
                    valueText: String(format: "%+.1f", viewModel.manualControls.exposureBias),
                    value: $viewModel.manualControls.exposureBias,
                    range: limits.minExposureBias...limits.maxExposureBias
                )
            }
        }
    }

    // MARK: - 对焦

    private var focusSection: some View {
        Section("对焦") {
            Toggle("锁定对焦", isOn: Binding(
                get: { viewModel.manualControls.focusLocked },
                set: { newValue in
                    if newValue { viewModel.willToggleLock(focus: true) }
                    viewModel.manualControls.focusLocked = newValue
                }
            ))
            if viewModel.manualControls.focusLocked {
                LabeledSlider(
                    title: "焦点（近 → 远）",
                    valueText: String(format: "%.2f", viewModel.manualControls.lensPosition),
                    value: $viewModel.manualControls.lensPosition,
                    range: 0...1
                )
            }
        }
    }

    // MARK: - 白平衡

    private var whiteBalanceSection: some View {
        Section("白平衡") {
            Toggle("锁定白平衡", isOn: Binding(
                get: { viewModel.manualControls.whiteBalanceLocked },
                set: { newValue in
                    if newValue { viewModel.willToggleLock(whiteBalance: true) }
                    viewModel.manualControls.whiteBalanceLocked = newValue
                }
            ))
            if viewModel.manualControls.whiteBalanceLocked {
                LabeledSlider(
                    title: "色温",
                    valueText: "\(Int(viewModel.manualControls.temperature))K",
                    value: $viewModel.manualControls.temperature,
                    range: 2500...8000
                )
                LabeledSlider(
                    title: "色调",
                    valueText: String(format: "%+.0f", viewModel.manualControls.tint),
                    value: $viewModel.manualControls.tint,
                    range: -150...150
                )
            }
        }
    }
}

/// 带标题和当前值的滑杆行。
private struct LabeledSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let title: String
    let valueText: String
    @Binding var value: V
    let range: ClosedRange<V>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
