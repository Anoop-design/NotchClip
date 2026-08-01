import AppKit
import SwiftUI

/// A compact two-step introduction: show the product first, then explain the
/// one optional permission. The permission screen becomes the ready state in
/// place so setup never turns into a long wizard.
struct ProductOnboardingView: View {
    private enum Step: Int, CaseIterable, Hashable {
        case welcome
        case permission
    }

    private enum FocusedAction: Hashable {
        case back
        case skip
        case primary
    }

    @Bindable var state: AccessibilityPermissionState
    let onEnable: () -> Void
    let onOpenSettings: () -> Void
    let onDone: () -> Void
    let hotKey: HotKeyDescription

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var step: Step
    @State private var movingForward = true
    @State private var hasRunWelcomeEntrance = false
    @State private var heroExpanded = false
    @State private var welcomeCopyVisible = false
    @State private var welcomeActionVisible = false
    @FocusState private var focusedAction: FocusedAction?
    @AccessibilityFocusState private var permissionStatusFocused: Bool

    init(
        state: AccessibilityPermissionState,
        onEnable: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onDone: @escaping () -> Void,
        hotKey: HotKeyDescription = .default,
        startsAtPermission: Bool = false
    ) {
        self.state = state
        self.onEnable = onEnable
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
        self.hotKey = hotKey
        _step = State(initialValue: startsAtPermission ? .permission : .welcome)
    }

    var body: some View {
        ZStack {
            NotchClipMaterialBackdrop()
                .ignoresSafeArea()

            Color.black
                .opacity(reduceTransparency ? 0.96 : 0.42)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(width: 840, height: 560)
        .task(id: step) {
            guard step == .welcome else { return }
            await runWelcomeEntranceIfNeeded()
        }
        .onAppear {
            focusedAction = isPrimaryActionAvailable ? .primary : nil
        }
        .onChange(of: welcomeActionVisible) { _, isVisible in
            guard isVisible, step == .welcome else { return }
            focusedAction = .primary
        }
        .onChange(of: state.permissionPageRequestID) { _, _ in
            guard step != .permission else { return }
            movingForward = true
            withAnimation(pageAnimation) {
                step = .permission
            }
            focusedAction = .primary
        }
        .onChange(of: state.setupAttemptID) { _, _ in
            guard !state.isGranted else { return }
            focusedAction = .primary
            permissionStatusFocused = true
        }
        .onChange(of: state.setupErrorMessage) { _, message in
            guard message != nil, !state.isGranted else { return }
            focusedAction = .primary
            permissionStatusFocused = true
        }
        .onChange(of: state.isGranted) { _, granted in
            guard granted else { return }
            focusedAction = .primary
            permissionStatusFocused = true
        }
        .onDisappear {
            state.endMonitoring()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NotchClipDesign.surfaceStrong)

                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.primaryText)
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            Text("NotchClip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchClipDesign.primaryText)

            Spacer()

            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(NotchClipDesign.secondaryText)
                .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        }
        .padding(.leading, 72)
        .padding(.trailing, 28)
        .frame(height: 56)
    }

    @ViewBuilder
    private var page: some View {
        Group {
            switch step {
            case .welcome:
                welcomePage
            case .permission:
                permissionPage
            }
        }
        .id(step)
        .transition(pageTransition)
    }

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)

            OnboardingNotchHero(
                isExpanded: heroExpanded,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency,
                hotKeySymbol: hotKey.symbolic
            )
            .frame(width: 552, height: 152)

            VStack(spacing: 7) {
                Text("Clipboard history, in your notch.")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.primaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text("Copy text, links, images, or files. Press \(hotKey.prose) to bring them back without leaving your current app.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 540)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(welcomeCopyVisible ? 1 : 0)
            .offset(y: reduceMotion || welcomeCopyVisible ? 0 : 6)
            .padding(.top, 17)

            workflowLine
                .opacity(welcomeCopyVisible ? 1 : 0)
                .offset(y: reduceMotion || welcomeCopyVisible ? 0 : 6)
                .padding(.top, 17)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 36)
    }

    private var workflowLine: some View {
        HStack(spacing: 11) {
            Text("Copy anything")

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)

            NotchClipKeycap(hotKey.symbolic)
                .accessibilityLabel(hotKey.spoken)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)

            Text("Click to paste or drag")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(NotchClipDesign.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Copy anything, press \(hotKey.spoken), then click to paste or drag")
    }

    private var permissionPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 8) {
                Text(permissionTitle)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.primaryText)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)

                Text(permissionSubtitle)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 560)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }

            permissionCard
                .frame(width: 580)
                .frame(minHeight: 136)
                .padding(.top, 28)

            Label("Clipboard history stays on this Mac.", systemImage: "lock.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .padding(.top, 18)

            if !state.isGranted {
                Text("Your clip stays on the clipboard, so Command–V still works. You can also drag clips without this permission.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)

                // The stale-grant trap: macOS keys this permission to the exact
                // build, so an updated copy shows as enabled in Settings while
                // the grant no longer applies. Shown only to users who have
                // been through the request before.
                if state.hasRequestedPermission {
                    Text("If NotchClip already appears in the Accessibility list but this still says it's required, remove it with the − button and add it again — macOS ties the permission to the exact copy of the app.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(NotchClipDesign.tertiaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }

            Spacer(minLength: 18)
        }
        .padding(.horizontal, 36)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: permissionPhase)
    }

    private var permissionCard: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(state.isGranted ? NotchClipDesign.surfaceSelected : NotchClipDesign.surfaceStrong)

                Image(systemName: permissionSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(permissionTone)
                    .symbolRenderingMode(.monochrome)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(permissionStatusTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.primaryText)

                Text(permissionStatusDetail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if state.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(NotchClipDesign.success)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            } else if state.isWaitingForPermission {
                ProgressView()
                    .controlSize(.small)
                    .tint(NotchClipDesign.primaryText)
                    .transition(.opacity)
                    .accessibilityLabel("Waiting for Accessibility permission")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .notchClipSurface(cornerRadius: 14, isSelected: state.isGranted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(permissionStatusTitle)
        .accessibilityValue(permissionStatusDetail)
        .accessibilityFocused($permissionStatusFocused)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step == .permission {
                Button(action: goBack) {
                    HStack(spacing: 9) {
                        Text("Back")
                        NotchClipKeycap("Esc")
                    }
                }
                .buttonStyle(
                    OnboardingActionButtonStyle(
                        kind: .secondary,
                        minimumWidth: 112,
                        isFocused: focusedAction == .back,
                        reduceMotion: reduceMotion
                    )
                )
                .keyboardShortcut(.cancelAction)
                .focused($focusedAction, equals: .back)
                .accessibilityHint("Returns to the introduction")
            }

            Spacer()

            if step == .permission, !state.isGranted {
                Button("Not now", action: onDone)
                    .buttonStyle(
                        OnboardingActionButtonStyle(
                            kind: .quiet,
                            minimumWidth: 92,
                            isFocused: focusedAction == .skip,
                            reduceMotion: reduceMotion
                        )
                    )
                    .focused($focusedAction, equals: .skip)
                    .accessibilityHint("Finishes setup without one-click paste")
            }

            Button(action: primaryAction) {
                HStack(spacing: 10) {
                    Text(primaryTitle)
                    Text("↵")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.52))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(
                OnboardingActionButtonStyle(
                    kind: .primary,
                    minimumWidth: primaryButtonWidth,
                    isFocused: focusedAction == .primary,
                    reduceMotion: reduceMotion
                )
            )
            .keyboardShortcut(.defaultAction)
            .focused($focusedAction, equals: .primary)
            .accessibilityHint(primaryHint)
            .disabled(!isPrimaryActionAvailable)
            .allowsHitTesting(isPrimaryActionAvailable)
            .accessibilityHidden(!isPrimaryActionAvailable)
            .opacity(isPrimaryActionAvailable ? 1 : 0)
        }
        .padding(.horizontal, 28)
        .frame(height: 76)
    }

    private var permissionPhase: Int {
        if state.isGranted { return 4 }
        if state.setupErrorMessage != nil { return 3 }
        if state.isWaitingForPermission { return 2 }
        if state.hasRequestedPermission { return 1 }
        return 0
    }

    private var isPrimaryActionAvailable: Bool {
        step != .welcome || welcomeActionVisible
    }

    private var permissionTitle: String {
        if state.isGranted { return "One-click paste is ready." }
        if state.setupErrorMessage != nil { return "System Settings didn’t open" }
        if state.hasRequestedPermission { return "Finish in System Settings" }
        return "Enable one-click paste"
    }

    private var permissionSubtitle: String {
        if state.isGranted {
            return "Press \(hotKey.prose), choose a clip, and keep moving."
        }
        return "Accessibility lets NotchClip press Command–V only after you choose a clip."
    }

    private var permissionSymbol: String {
        if state.isGranted { return "checkmark" }
        if state.setupErrorMessage != nil { return "exclamationmark.triangle.fill" }
        return "hand.raised.fill"
    }

    private var permissionTone: Color {
        if state.isGranted { return NotchClipDesign.success }
        if state.setupErrorMessage != nil { return NotchClipDesign.warning }
        return NotchClipDesign.primaryText
    }

    private var permissionStatusTitle: String {
        if state.isGranted { return "Accessibility enabled" }
        if state.setupErrorMessage != nil { return "Couldn’t open System Settings" }
        if state.isWaitingForPermission { return "Waiting for Accessibility…" }
        if state.hasRequestedPermission { return "Accessibility is still off" }
        return "Accessibility is off"
    }

    private var permissionStatusDetail: String {
        if state.isGranted {
            return "Choose a clip and NotchClip returns to the app you were using."
        }
        if let setupErrorMessage = state.setupErrorMessage {
            return setupErrorMessage
        }
        if state.isWaitingForPermission {
            return "Turn on NotchClip in Privacy & Security. This window will update automatically."
        }
        if state.hasRequestedPermission {
            return "Open Accessibility settings and enable NotchClip. If it is already enabled, turn it off and on once to refresh macOS."
        }
        return "NotchClip uses this only to paste after you select a clip."
    }

    private var primaryTitle: String {
        switch step {
        case .welcome:
            return "Continue"
        case .permission:
            if state.isGranted { return "Start Using NotchClip" }
            if state.setupErrorMessage != nil { return "Try Opening Settings" }
            return state.hasRequestedPermission ? "Open System Settings" : "Request Access"
        }
    }

    private var primaryButtonWidth: CGFloat {
        switch step {
        case .welcome:
            return 138
        case .permission:
            if state.isGranted { return 196 }
            if state.setupErrorMessage != nil { return 184 }
            return state.hasRequestedPermission ? 188 : 156
        }
    }

    private var primaryHint: String {
        switch step {
        case .welcome:
            return "Shows the Accessibility setup step"
        case .permission:
            if state.isGranted { return "Finishes setup and closes this window" }
            if state.hasRequestedPermission || state.setupErrorMessage != nil {
                return "Opens Privacy and Security settings so you can allow NotchClip"
            }
            return "Asks macOS for Accessibility permission"
        }
    }

    private func primaryAction() {
        guard isPrimaryActionAvailable else { return }
        switch step {
        case .welcome:
            movingForward = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(pageAnimation) {
                step = .permission
            }
            focusedAction = .primary
        case .permission:
            if state.isGranted {
                onDone()
            } else if state.hasRequestedPermission || state.setupErrorMessage != nil {
                onOpenSettings()
            } else {
                onEnable()
            }
        }
    }

    private func goBack() {
        movingForward = false
        withAnimation(pageAnimation) {
            step = .welcome
        }
        focusedAction = .primary
    }

    private var pageTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        let insertionOffset: CGFloat = movingForward ? 14 : -14
        let removalOffset: CGFloat = movingForward ? -14 : 14
        return .asymmetric(
            insertion: .modifier(
                active: OnboardingPageOffset(opacity: 0, offsetX: insertionOffset),
                identity: OnboardingPageOffset(opacity: 1, offsetX: 0)
            ),
            removal: .modifier(
                active: OnboardingPageOffset(opacity: 0, offsetX: removalOffset),
                identity: OnboardingPageOffset(opacity: 1, offsetX: 0)
            )
        )
    }

    private var pageAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.92)
    }

    @MainActor
    private func runWelcomeEntranceIfNeeded() async {
        guard !hasRunWelcomeEntrance else { return }
        hasRunWelcomeEntrance = true

        guard !reduceMotion else {
            heroExpanded = true
            welcomeCopyVisible = true
            welcomeActionVisible = true
            return
        }

        do {
            try await Task.sleep(nanoseconds: 280_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.44, dampingFraction: 0.90)) {
            heroExpanded = true
        }

        do {
            try await Task.sleep(nanoseconds: 240_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.20)) {
            welcomeCopyVisible = true
        }

        do {
            try await Task.sleep(nanoseconds: 140_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            welcomeActionVisible = true
        }
    }
}

private struct OnboardingNotchHero: View {
    let isExpanded: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let hotKeySymbol: String

    var body: some View {
        ZStack(alignment: .top) {
            OnboardingNotchShell(
                isExpanded: isExpanded,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency
            )

            heroContent
                .opacity(isExpanded ? 1 : 0)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .easeOut(duration: 0.16).delay(0.22),
                    value: isExpanded
                )
        }
        .frame(width: 552, height: 152, alignment: .top)
        .accessibilityHidden(true)
    }

    private var heroContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Quick Paste", systemImage: "rectangle.on.rectangle.angled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.primaryText)

                Spacer()

                NotchClipKeycap(hotKeySymbol)
            }
            .frame(height: 28)

            HStack(spacing: 8) {
                OnboardingSampleClip(symbol: "text.alignleft", title: "Project notes")
                OnboardingSampleClip(symbol: "link", title: "design.apple.com")
                OnboardingSampleClip(symbol: "photo", title: "Screenshot")

                VStack(spacing: 7) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("All Clips")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(NotchClipDesign.secondaryText)
                .frame(width: 88, height: 66)
                .notchClipSurface(cornerRadius: 11)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 38)
        .frame(width: 552, height: 152, alignment: .top)
    }
}

private struct OnboardingSampleClip: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NotchClipDesign.primaryText)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .notchClipSurface(cornerRadius: 11)
    }
}

private struct OnboardingNotchShell: NSViewRepresentable {
    let isExpanded: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> NotchChromeView {
        let view = NotchChromeView(frame: NSRect(x: 0, y: 0, width: 552, height: 152))
        view.updateShell(width: 156, height: 34, attachesToNotch: true)
        view.preferOpaque = reduceTransparency
        view.shellProgress = isExpanded ? 1 : 0
        return view
    }

    func updateNSView(_ view: NotchChromeView, context: Context) {
        view.updateShell(width: 156, height: 34, attachesToNotch: true)
        view.preferOpaque = reduceTransparency

        let target: CGFloat = isExpanded ? 1 : 0
        guard abs(view.shellProgress - target) > 0.001 else { return }

        guard !reduceMotion else {
            view.shellProgress = target
            return
        }

        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.44
            animation.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.20,
                0.80,
                0.20,
                1.00
            )
            view.animator().shellProgress = target
        }
    }
}

private struct OnboardingPageOffset: ViewModifier {
    let opacity: Double
    let offsetX: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(x: offsetX)
    }
}

private enum OnboardingActionKind {
    case primary
    case secondary
    case quiet
}

private struct OnboardingActionButtonStyle: ButtonStyle {
    let kind: OnboardingActionKind
    let minimumWidth: CGFloat
    let isFocused: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        OnboardingActionButtonBody(
            configuration: configuration,
            kind: kind,
            minimumWidth: minimumWidth,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )
    }
}

private struct OnboardingActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: OnboardingActionKind
    let minimumWidth: CGFloat
    let isFocused: Bool
    let reduceMotion: Bool

    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.black.opacity(0.88) : NotchClipDesign.primaryText)
            .padding(.horizontal, 14)
            .frame(minWidth: minimumWidth, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(background)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(stroke, lineWidth: isFocused ? 1.5 : 1)
            }
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        switch kind {
        case .primary:
            shape.fill(Color.white.opacity(isHovering ? 0.98 : 0.92))
        case .secondary:
            shape.fill(isHovering ? NotchClipDesign.surfaceHover : NotchClipDesign.surface)
        case .quiet:
            shape.fill(isHovering ? NotchClipDesign.surfaceHover : Color.clear)
        }
    }

    private var stroke: Color {
        if isFocused { return NotchClipDesign.borderSelected }
        switch kind {
        case .primary:
            return Color.white.opacity(0.62)
        case .secondary:
            return isHovering ? NotchClipDesign.borderHover : NotchClipDesign.border
        case .quiet:
            return isHovering ? NotchClipDesign.border : .clear
        }
    }
}
