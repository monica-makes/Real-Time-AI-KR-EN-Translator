import SwiftUI

#if DEBUG
/// The shell of the Debug layout panels (home screen, manual pairing): a round toggle button, then
/// a dark card with a title, Reset, Copy, a top / bottom switch and a close button over one row per
/// value. Tuned values last until the app relaunches; Copy puts them on the pasteboard for the code.
struct LayoutTunerPanel<Rows: View>: View {
    private let title: String
    private let toggleIcon: String
    private let toggleOnLeading: Bool
    private let isDefault: Bool
    private let onReset: () -> Void
    private let summary: () -> String
    private let rows: Rows

    @State private var isOpen: Bool
    /// The panel can sit at the top so it doesn't cover what it's tuning
    @State private var panelAtTop = false
    @State private var copied = false

    /// `launchArgument` opens the panel on launch (e.g. `-homeLayoutPanel`); `toggleOnLeading`
    /// puts the closed panel's button in the bottom-left corner instead of the bottom-right
    init(_ title: String, toggleIcon: String = "ladybug.fill", toggleOnLeading: Bool = false,
         launchArgument: String? = nil, isDefault: Bool, onReset: @escaping () -> Void,
         summary: @escaping () -> String, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.toggleIcon = toggleIcon
        self.toggleOnLeading = toggleOnLeading
        self.isDefault = isDefault
        self.onReset = onReset
        self.summary = summary
        self.rows = rows()
        _isOpen = State(initialValue: launchArgument.map { ProcessInfo.processInfo.arguments.contains($0) } ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            if panelAtTop, isOpen { panel }
            Spacer(minLength: 0)
            if !panelAtTop, isOpen { panel }
            if !isOpen {
                HStack {
                    if !toggleOnLeading { Spacer() }
                    toggle
                    if toggleOnLeading { Spacer() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .hiddenAsLayoutTuner()
    }

    private var toggle: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isOpen = true }
        } label: {
            Image(systemName: toggleIcon)
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.6)))
        }
    }

    /// Compact: one line per value
    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                smallButton("Reset") {
                    withAnimation(.easeInOut(duration: 0.25)) { onReset() }
                }
                .disabled(isDefault)
                .opacity(isDefault ? 0.4 : 1)
                smallButton(copied ? "Copied" : "Copy") {
                    let text = summary()
                    UIPasteboard.general.string = text
                    print(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                iconButton(panelAtTop ? "arrow.down" : "arrow.up") {
                    withAnimation(.easeInOut(duration: 0.25)) { panelAtTop.toggle() }
                }
                iconButton("xmark") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isOpen = false }
                }
            }

            rows
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.78))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
        .transition(.move(edge: panelAtTop ? .top : .bottom).combined(with: .opacity))
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// One tunable value in a LayoutTunerPanel: label, -, 1pt slider, +, value
struct LayoutTunerRow: View {
    private let label: String
    private let value: CGFloat
    private let range: ClosedRange<CGFloat>
    private let set: (CGFloat) -> Void

    init(_ label: String, value: CGFloat, range: ClosedRange<CGFloat>, set: @escaping (CGFloat) -> Void) {
        self.label = label
        self.value = value
        self.range = range
        self.set = set
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 80, alignment: .leading)
            nudge("minus") { set((value - 1).rounded()) }
            Slider(value: Binding(get: { value }, set: { set($0.rounded()) }), in: range)
                .tint(AppColors.gradientPeach)
                .controlSize(.small)
            nudge("plus") { set((value + 1).rounded()) }
            Text(String(format: "%.0f", value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColors.gradientPeach)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func nudge(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
#endif
