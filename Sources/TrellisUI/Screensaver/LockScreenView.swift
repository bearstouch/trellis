import SwiftUI
import TrellisCore

extension LockScreenStyle {
    /// Where the clock sits, so it never fights the animation: in the middle, in the lower left, or left out (Cipher Wall
    /// spells its own message).
    enum ClockPlacement { case center, corner, none }
    var clockPlacement: ClockPlacement {
        switch self {
        case .vaultDial, .redactedShell, .signalLost: .center
        case .ridgelines: .corner
        case .cipherWall: .none
        }
    }
    /// A soft wash of the background behind the clock where the animation runs underneath it.
    var clockBackdrop: Bool { self != .vaultDial }
}

/// The lock screen (FR-LK02, FR-LK05..FR-LK07): an animation in the pane theme's colours, the time, and how to get back in.
/// It shows nothing from the workspace. With no `onUnlock` it is a preview (Settings).
struct LockScreenView: View {
    let style: LockScreenStyle
    let palette: ScreensaverPalette
    let animated: Bool
    var runningSessions = 0
    var unlocking = false
    var onUnlock: (() -> Void)?

    private var ink: Color { Color(themeRGB: palette[.accent]) }
    private func mono(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size) }

    var body: some View {
        GeometryReader { geometry in
            let h = geometry.size.height
            ZStack {
                ScreensaverCanvas(lock: style, palette: palette, animated: animated, onMouseDown: onUnlock)
                if palette.isDark { Scanlines().allowsHitTesting(false) }
                overlay(height: h, width: geometry.size.width).allowsHitTesting(false)
            }
        }
        .background(Color(themeRGB: palette.background))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Trellis is locked"))
        .accessibilityHint(L("Activate to unlock with Touch ID or your password"))
        .accessibilityAddTraits(onUnlock == nil ? [] : .isButton)
        .accessibilityAction { onUnlock?() }
    }

    private var sessionsText: String {
        switch runningSessions {
        case 0: L("No sessions running")
        case 1: L("1 session running")
        default: L("%d sessions running", runningSessions)
        }
    }

    @ViewBuilder
    private func overlay(height h: CGFloat, width w: CGFloat) -> some View {
        let small = max(9, h * 0.026), glow = palette.isDark ? ink.opacity(0.65) : .clear
        ZStack {
            VStack {
                HStack {
                    Text(L("Trellis · Locked")).textCase(.uppercase)
                    Spacer()
                    Text(sessionsText).textCase(.uppercase)
                }
                .font(mono(small)).tracking(small * 0.14).opacity(0.6)
                Spacer()
                Text(unlocking ? L("Waiting for Touch ID or your password…") : L("Click or press any key to unlock"))
                    .font(mono(max(9, h * 0.028))).tracking(1).opacity(0.75)
            }
            .padding(.horizontal, w * 0.04).padding(.top, h * 0.04).padding(.bottom, h * 0.045)
            switch style.clockPlacement {
            case .center: clock(height: h, timeSize: max(22, h * 0.15), alignment: .center, glow: glow)
            case .corner:
                clock(height: h, timeSize: max(18, h * 0.11), alignment: .leading, glow: glow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, w * 0.06).padding(.bottom, h * 0.12)
            case .none: EmptyView()
            }
        }
        .foregroundStyle(ink)
    }

    private func clock(height h: CGFloat, timeSize: CGFloat, alignment: HorizontalAlignment, glow: Color) -> some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: alignment, spacing: h * 0.014) {
                Image(systemName: "lock.fill").font(.system(size: max(12, h * 0.05), weight: .regular)).shadow(color: glow, radius: h * 0.012)
                Text(context.date, format: .dateTime.hour().minute()).font(mono(timeSize)).monospacedDigit().shadow(color: glow, radius: h * 0.02)
                Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).textCase(.uppercase)
                    .font(mono(max(9, h * 0.03))).tracking(2).opacity(0.7)
            }
            .background {
                if style.clockBackdrop {
                    let bg = Color(themeRGB: palette.background)
                    RadialGradient(stops: [.init(color: bg.opacity(0.92), location: 0.45), .init(color: bg.opacity(0), location: 1)], center: .center, startRadius: 0, endRadius: h * 0.32)
                        .frame(width: h * 0.95, height: h * 0.62)
                }
            }
        }
    }
}

/// Faint scanlines and a vignette, the phosphor screen look in dark themes.
private struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 2
            var lines = Path()
            while y < size.height { lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)); y += 3 }
            ctx.fill(lines, with: .color(.black.opacity(0.2)))
            let radius = max(size.width, size.height) * 0.75
            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [.clear, .clear, .black.opacity(0.4)]), center: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0, endRadius: radius))
        }
    }
}
