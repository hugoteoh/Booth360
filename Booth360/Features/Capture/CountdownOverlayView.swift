import SwiftUI

/// 全屏倒数覆盖层。数字每秒缩放跳动，点「取消」返回待机。
struct CountdownOverlayView: View {
    let secondsRemaining: Int
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 40) {
                Text("\(secondsRemaining)")
                    .font(.system(size: 160, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .id(secondsRemaining)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
                    .shadow(radius: 20)

                Text("准备好，马上开拍！")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Button(action: onCancel) {
                    Text("取消")
                        .font(.headline)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.2), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .animation(.spring(duration: 0.3), value: secondsRemaining)
    }
}

#Preview {
    CountdownOverlayView(secondsRemaining: 3, onCancel: {})
}
