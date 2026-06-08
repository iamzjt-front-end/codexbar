import SwiftUI

struct RefreshIconView: View {
    let isRefreshing: Bool
    let size: CGFloat
    let fontSize: CGFloat
    let weight: Font.Weight

    @State private var rotation: Double = 0
    @State private var spinTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: fontSize, weight: weight))
            .symbolRenderingMode(.hierarchical)
            .rotationEffect(.degrees(rotation))
            .frame(width: size, height: size)
            .onAppear { updateSpinTask() }
            .onChange(of: isRefreshing) { _, _ in
                updateSpinTask()
            }
            .onDisappear {
                spinTask?.cancel()
                spinTask = nil
            }
    }

    private func updateSpinTask() {
        if isRefreshing {
            startSpinning()
        } else {
            stopSpinning()
        }
    }

    private func startSpinning() {
        guard spinTask == nil else { return }

        spinTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.linear(duration: 0.92)) {
                    rotation += 360
                }
                try? await Task.sleep(nanoseconds: 920_000_000)
            }
        }
    }

    private func stopSpinning() {
        spinTask?.cancel()
        spinTask = nil
    }
}
