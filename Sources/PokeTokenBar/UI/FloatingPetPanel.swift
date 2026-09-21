import AppKit
import SwiftUI

/// 데스크톱 위에 떠 있는 컴패니언 포켓몬 오버레이(옵트인, 설정 → 플로팅 펫).
/// - 드래그: 커스텀 `mouseDragged` (클릭과 충돌하지 않음).
/// - 클릭 → 팝오버, 우클릭 → 메뉴, 호버 → 오늘 사용량 콜아웃.
/// - Limit-alert speech bubbles grow the panel; persisted origin is the *pet*, not the panel.
/// - 에너지: 숨김·슬립 시 호스팅 트리 해제.
@MainActor
final class FloatingPetController: NSObject, NSWindowDelegate {
    private let store: UsageStore
    private let companion: CompanionStore
    private let defaults: UserDefaults
    private var panel: NSPanel?
    private var hoverPanel: NSPanel?
    private var displayAwake = true
    private var builtAnimated: Bool?
    /// 말풍선 퇴장 애니메이션이 끝나기를 기다리는 축소 작업. 새 말풍선이 뜨면 취소된다.
    private var shrinkTask: Task<Void, Never>?
    private var powerObserver: NSObjectProtocol?

    private static let originXKey = "floatingPetOriginX"
    private static let originYKey = "floatingPetOriginY"

    /// Squared movement (pt²) below which a mouse-up counts as a click, not a drag.
    static let clickThresholdSquared: CGFloat = 16  // ~4pt

    /// 말풍선이 차지할 최소 높이(pt). 내용이 이보다 크면 잰 값을 쓴다 — 줄 수를 제한하지 않으므로
    /// 긴 알림은 패널이 그만큼 위로 자란다.
    static let bubbleHeadroom: CGFloat = 94
    /// 말풍선과 pet 사이 간격. `FloatingPetView` 의 `VStack(spacing:)` 과 같은 값이어야 한다.
    static let bubblePetSpacing: CGFloat = 8

    /// 이 내용을 그리는 데 필요한 여유 높이. 화면을 넘지 않도록 상한을 둔다 —
    /// 알림 본문은 길이 제한이 없어서 한 통이 화면보다 길 수 있다.
    static func headroom(for content: UsageStore.BubbleContent?,
                         petSize: CGFloat,
                         screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 900) -> CGFloat {
        guard let content else { return 0 }
        let measured = measureSpeechBubbleLayout(
            title: content.header?.name ?? content.title, body: content.body,
            subtitle: content.header?.subtitle ?? "").size.height
        let ceiling = max(bubbleHeadroom, screenHeight - petSize - bubbleShadowMargin)
        return min(ceiling, max(bubbleHeadroom, measured + bubblePetSpacing + 2))
    }
    /// Minimum panel width while a bubble is showing.
    static let bubbleMinWidth: CGFloat = 270
    /// 말풍선 둘레에 남기는 여백. 말풍선이 패널 경계에 딱 붙으면 그림자가 창 밖으로 잘려
    /// 좌우가 깎여 보인다. 그림자 반경 4pt 와 아래로 2pt 밀린 것을 덮는 크기다.
    static let bubbleShadowMargin: CGFloat = 8
    /// Horizontal padding inside the bubble chrome (each side). Content + 2× this = `bubbleMinWidth`.
    static let bubbleHorizontalPadding: CGFloat = 8
    /// Fixed text column — wraps instead of growing past the panel (`bubbleMinWidth` − 16).
    static let bubbleContentWidth: CGFloat = bubbleMinWidth - (bubbleHorizontalPadding * 2)
    /// 말풍선 글자 크기. 측정(`measureSpeechBubbleLayout`)과 뷰가 같은 값을 써야
    /// 패널 높이 계산이 화면과 어긋나지 않는다.
    static let bubbleTitleFontSize: CGFloat = 12
    static let bubbleBodyFontSize: CGFloat = 11
    /// 말풍선 퇴장 애니메이션이 눈에서 사라질 때까지의 시간(초). `FloatingPetView` 의
    /// `.spring(response: 0.3)` 이 잦아드는 데 걸리는 시간보다 넉넉히 잡는다.
    static let bubbleExitDuration: TimeInterval = 0.45

    /// 호버 툴팁에 주간 사용률을 띄울 모델. 이름으로 찾으므로 여기만 바꾸면 대상이 바뀐다.
    static let hoverModelName = "Fable"

    /// 패널 크기를 언제 바꿀지(순수 — AppKit 없이 테스트한다).
    enum FrameUpdate: Equatable {
        case none                 // 이미 목표 크기다. 다시 그리라고 시키면 진행 중인 애니메이션이 끊긴다.
        case now                  // 말풍선이 들어올 자리를 먼저 넓힌다.
        case afterBubbleExit      // 말풍선이 빠져나간 뒤에 줄인다.
    }

    static func frameUpdate(current: NSRect, target: NSRect, showingBubble: Bool) -> FrameUpdate {
        guard current != target else { return .none }
        return showingBubble ? .now : .afterBubbleExit
    }
    /// 말풍선과 호버 툴팁이 같은 모서리를 쓴다. 한쪽만 바꾸면 두 표면의 모양이 갈린다.
    /// `Shape` 가 기본값으로 읽으므로 격리에서 뺀다.
    nonisolated static let bubbleCornerRadius: CGFloat = 8
    /// 두 표면의 외곽선 굵기.
    nonisolated static let bubbleBorderWidth: CGFloat = 0.5
    /// 펫 머리의 둘째 줄(단계·성격) 글자 크기. `.caption2` 와 같은 값이어야 측정이 맞는다.
    static let bubbleSubtitleFontSize: CGFloat = 10

    /// Chrome size plus the signals the view actually fails on: wrap count and
    /// single-line width vs the content column.
    struct SpeechBubbleLayout: Equatable {
        var size: NSSize
        var bodyLineCount: Int
        /// 제목도 외부 문자열(대화방 이름·세션 이름)이 들어오면서 2줄까지 번진다.
        /// 이 값이 없던 동안에는 제목이 몇 줄인지 볼 수 없어 headroom 초과를 걸러낼 수 없었다.
        var titleLineCount: Int
        var unclampedTitleWidth: CGFloat
        var unclampedBodyWidth: CGFloat
    }

    /// AppKit 호버 콜아웃에 사용할 appearance 해석 완료 색상.
    ///
    /// 이 콜아웃은 SwiftUI가 아니라 `NSTextField`와 레이어 기반 `NSView`로 조립된다.
    /// 텍스트 필드에 semantic `NSColor`를 그대로 지정하면 뷰의 effective appearance로
    /// 해석되지만, `windowBackgroundColor.cgColor`는 현재 그리기 appearance에서 즉시
    /// 색상이 굳어진다. 세 색상을 하나의 appearance에서 함께 해석해야 글자와 외곽선이
    /// 같은 라이트/다크 모드를 유지한다.
    struct HoverCalloutColors {
        var text: NSColor
        var background: NSColor
        var border: NSColor
    }

    static func hoverCalloutColors(for appearance: NSAppearance) -> HoverCalloutColors {
        HoverCalloutColors(
            text: snapshot(NSColor.labelColor, for: appearance),
            background: snapshot(NSColor.windowBackgroundColor, for: appearance),
            border: snapshot(NSColor.separatorColor, for: appearance))
    }

    private static func snapshot(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: color.cgColor) ?? color
        }
        return resolved
    }

    private var onOpenPopover: (() -> Void)?
    private var onHide: (() -> Void)?

    init(store: UsageStore, companion: CompanionStore, defaults: UserDefaults = .standard,
         onOpenPopover: (() -> Void)? = nil, onHide: (() -> Void)? = nil) {
        self.store = store
        self.companion = companion
        self.defaults = defaults
        self.onOpenPopover = onOpenPopover
        self.onHide = onHide
        super.init()
        observeSettings()
        observePowerState()
        sync()
    }

    static func isClick(from start: NSPoint, to end: NSPoint,
                        thresholdSquared: CGFloat = clickThresholdSquared) -> Bool {
        let dx = end.x - start.x, dy = end.y - start.y
        return dx * dx + dy * dy < thresholdSquared
    }

    func setDisplayAwake(_ awake: Bool) {
        displayAwake = awake
        sync()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = store.floatingPetEnabled
            _ = store.floatingPetSize
            _ = store.currentBubble
            _ = store.todayTotalTokens
            _ = store.highestLimitUtilization
            _ = store.limits             // hover 툴팁의 세션·모델별 주간 %가 여기서 파생된다
            _ = store.limitDisplayMode   // hover 툴팁 %가 파생되는 값 — 수동 관찰 표면은 파생 원천을 직접 추적(defect-log §표시·UI)
            _ = companion.language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.observeSettings()
            }
        }
    }

    private func observePowerState() {
        powerObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    static func shouldAnimate(lowPower: Bool) -> Bool { !lowPower }

    /// Panel size for a given pet size and bubble visibility. Pure — tested without AppKit layout.
    /// `headroom` 이 0 이면 말풍선이 없는 상태다. 그 밖에는 잰 높이만큼 패널이 위로 자란다.
    static func panelSize(petSize: CGFloat, headroom: CGFloat) -> NSSize {
        guard headroom > 0 else { return NSSize(width: petSize, height: petSize) }
        // 그림자가 번질 자리를 좌우와 위에 더한다. 말풍선 자체 폭은 bubbleMinWidth 그대로다.
        return NSSize(width: max(petSize, bubbleMinWidth + bubbleShadowMargin * 2),
                      height: petSize + headroom + bubbleShadowMargin)
    }

    static func panelOrigin(petOrigin: NSPoint, petSize: CGFloat, panelSize: NSSize) -> NSPoint {
        let xInset = max(0, (panelSize.width - petSize) / 2)
        return NSPoint(x: petOrigin.x - xInset, y: petOrigin.y)
    }

    static func petOrigin(panelOrigin: NSPoint, petSize: CGFloat, panelSize: NSSize) -> NSPoint {
        let xInset = max(0, (panelSize.width - petSize) / 2)
        return NSPoint(x: panelOrigin.x + xInset, y: panelOrigin.y)
    }

    /// Measure speech-bubble chrome for a title/body at the fixed content width (wrapping).
    /// Pure AppKit typography — keeps the layout test free of SwiftUI hosting.
    /// The alert text, with its Claude account only when it still fits: the percentage matters more.
    /// 말풍선 높이가 내용을 따라가면서 잘림 판정(`wouldTruncate`)이 사라졌다. 그래도 길면
    /// 계정명을 빼는 규칙은 살린다 — 좁을 때 퍼센트가 계정명보다 중요하다는 판단은 그대로다.
    static let bubbleBodyCompactLineLimit = 2

    static func bubbleBody(for alert: UsageStore.LimitAlert, title: String, l: L) -> String {
        let full = alert.body(l)
        guard alert.account != nil,
              measureSpeechBubbleLayout(title: title, body: full).bodyLineCount
                  > bubbleBodyCompactLineLimit else { return full }
        return alert.body(l, withAccount: false)
    }

    static func measureSpeechBubble(title: String, body: String,
                                    contentWidth: CGFloat = bubbleContentWidth) -> NSSize {
        measureSpeechBubbleLayout(title: title, body: body, contentWidth: contentWidth).size
    }

    /// Layout the view draws: unconstrained chrome (`size`) plus wrap count and
    /// single-line widths. `size.width` is clamped to the column (cannot fail a
    /// `≤ panel.width` assert); `unclamped*Width` is the check that can.
    static func measureSpeechBubbleLayout(title: String, body: String, subtitle: String = "",
                                          contentWidth: CGFloat = bubbleContentWidth) -> SpeechBubbleLayout {
        let titleFont = NSFont.systemFont(ofSize: bubbleTitleFontSize, weight: .bold)
        let bodyFont = NSFont.systemFont(ofSize: bubbleBodyFontSize)
        let wrap = NSSize(width: contentWidth, height: 10_000)
        let unclamped = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 10_000)
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let titleRect = (title as NSString).boundingRect(
            with: wrap, options: opts, attributes: [.font: titleFont])
        let bodyRect = (body as NSString).boundingRect(
            with: wrap, options: opts, attributes: [.font: bodyFont])
        let unclampedTitle = (title as NSString).boundingRect(
            with: unclamped, options: opts, attributes: [.font: titleFont])
        let unclampedBody = (body as NSString).boundingRect(
            with: unclamped, options: opts, attributes: [.font: bodyFont])
        // 펫이 말하는 말풍선은 제목 아래에 단계·성격 한 줄이 더 붙는다.
        let subtitleRect = subtitle.isEmpty ? .zero : (subtitle as NSString).boundingRect(
            with: wrap, options: opts, attributes: [.font: NSFont.systemFont(ofSize: bubbleSubtitleFontSize)])
        let textWidth = min(contentWidth, max(titleRect.width, bodyRect.width, subtitleRect.width))
        let subtitleHeight = subtitle.isEmpty ? 0 : 1 + ceil(subtitleRect.height)
        let textHeight = ceil(titleRect.height) + subtitleHeight + 2 + ceil(bodyRect.height)
        // Match SpeechBubbleView: horizontal padding ×2, vertical 6, bottom pad 6 for the tail.
        let hPad = bubbleHorizontalPadding * 2
        let bodyLineCount = wrappedLineCount(body, font: bodyFont, width: contentWidth)
        return SpeechBubbleLayout(
            size: NSSize(width: textWidth + hPad, height: textHeight + 12 + 6),
            bodyLineCount: bodyLineCount,
            titleLineCount: wrappedLineCount(title, font: titleFont, width: contentWidth),
            unclampedTitleWidth: unclampedTitle.width,
            unclampedBodyWidth: unclampedBody.width)
    }

    /// Wrap count at `width` using the same `boundingRect` path as `size`, so a
    /// height-jump fixture and `bodyLineCount` cannot disagree.
    private static func wrappedLineCount(_ string: String, font: NSFont, width: CGFloat) -> Int {
        guard !string.isEmpty else { return 0 }
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let wrapped = (string as NSString).boundingRect(
            with: NSSize(width: width, height: 10_000), options: opts, attributes: [.font: font])
        let single = ("Ay" as NSString).boundingRect(
            with: NSSize(width: 10_000, height: 10_000), options: opts, attributes: [.font: font])
        let unit = max(single.height, 1)
        return max(1, Int((wrapped.height / unit).rounded()))
    }

    private func sync() {
        guard store.floatingPetEnabled, displayAwake else { hide(); return }
        show()
    }

    private func show() {
        let p = panel ?? makePanel()
        panel = p
        let wantAnimated = Self.shouldAnimate(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if p.contentView == nil || builtAnimated != wantAnimated {
            let hosting = PetHostingView(rootView: AnyView(
                FloatingPetView(animated: wantAnimated).environment(store).environment(companion)))
            hosting.onOpenPopover = onOpenPopover
            hosting.onHide = onHide
            hosting.languageProvider = { [weak self] in self?.companion.language ?? .systemDefault }
            hosting.onHoverChange = { [weak self] hovering in
                if hovering { self?.showHoverCallout() } else { self?.hideHoverCallout() }
            }
            p.contentView = hosting
            builtAnimated = wantAnimated
        }
        if let hosting = p.contentView as? PetHostingView {
            let content = currentHoverContent()
            hosting.toolTip = [content.title, content.body]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
        let petSize = CGFloat(store.floatingPetSize)
        let showingBubble = store.currentBubble != nil
        let target = targetFrame(petSize: petSize, headroom: currentHeadroom(petSize: petSize))
        shrinkTask?.cancel()
        shrinkTask = nil
        switch Self.frameUpdate(current: p.frame, target: target, showingBubble: showingBubble) {
        case .none:
            break
        case .now:
            p.setFrame(target, display: true)
        case .afterBubbleExit:
            // 말풍선이 빠져나가는 동안 패널을 먼저 줄이면 그 애니메이션이 창 밖으로 잘려
            // 뚝 끊겨 보인다. 퇴장이 끝난 뒤에 줄인다.
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.bubbleExitDuration * 1_000_000_000))
                guard !Task.isCancelled, let self, let p = self.panel, p.isVisible,
                      self.store.currentBubble == nil else { return }
                p.setFrame(self.targetFrame(petSize: CGFloat(self.store.floatingPetSize),
                                            headroom: 0), display: true)
                // 패널이 줄면 그 위에 붙어 있던 툴팁도 따라 내려와야 한다.
                if self.hoverPanel?.isVisible == true { self.showHoverCallout() }
            }
        }
        p.orderFrontRegardless()
        if hoverPanel?.isVisible == true { showHoverCallout() }
    }

    private func hide() {
        shrinkTask?.cancel()
        shrinkTask = nil
        hideHoverCallout()
        guard let p = panel else { return }
        p.orderOut(nil)
        p.contentView = nil
        builtAnimated = nil
    }

    private func currentHoverRows() -> [FloatingPetView.LimitRow] {
        FloatingPetView.hoverLimitRows(
            sessionPercent: store.sessionUtilization,
            weeklyPercent: store.weeklyUtilization,
            modelWeeklyPercent: store.weeklyUtilization(forModel: Self.hoverModelName),
            modelName: Self.hoverModelName,
            // 알 상태에는 경험치 막대가 없다. 부화 진행은 팝오버가 따로 보여준다.
            experiencePercent: companion.isEgg ? nil : companion.progress * 100,
            l: L(companion.language))
    }

    private func currentHoverContent() -> UsageStore.BubbleContent {
        FloatingPetView.hoverTooltip(
            rows: currentHoverRows(),
            todayTokens: store.todayTotalTokens,
            mode: store.limitDisplayMode,
            l: L(companion.language))
    }

    private func showHoverCallout() {
        guard let pet = panel, pet.isVisible else { return }
        // 말풍선이 떠 있어도 띄운다. 말풍선이 뜨면 패널이 위로 커지고 툴팁은 그 패널 위에 붙으므로
        // 서로 가리지 않는다. 마우스를 올렸는데 아무것도 안 뜨는 쪽이 더 답답하다.
        let appearance = NSApp.effectiveAppearance
        let colors = Self.hoverCalloutColors(for: appearance)
        // 배경과 꼬리는 AppKit 이 그리고(색을 한 appearance 에서 함께 해석해야 한다), 내용만
        // SwiftUI 로 얹는다. 팝오버의 `LimitProgressBar` 를 그대로 써서 막대 규칙이 갈라지지 않는다.
        let body = NSHostingView(rootView: AnyView(
            HoverCalloutContent(header: companion.petHeader, content: currentHoverContent(),
                                rows: currentHoverRows(),
                                mode: store.limitDisplayMode, l: L(companion.language))
                .environment(store)))
        body.appearance = appearance
        let fitting = body.fittingSize

        let pad: CGFloat = 8
        let tail = HoverCalloutView.tailSize.height
        let size = NSSize(width: fitting.width + pad * 2,
                          height: fitting.height + pad * 2 + tail)
        let container = HoverCalloutView(frame: NSRect(origin: .zero, size: size))
        container.appearance = appearance
        container.background = colors.background
        container.border = colors.border
        // 꼬리가 위로 갔으므로 글자 상자는 아래쪽 여백만 띄운다.
        body.frame = NSRect(x: pad, y: pad, width: fitting.width, height: fitting.height)
        container.addSubview(body)

        let hp = hoverPanel ?? makeHoverPanel()
        hoverPanel = hp
        hp.appearance = appearance
        hp.contentView = container
        hp.setContentSize(size)
        let petFrame = pet.frame
        // 말풍선은 위, 툴팁은 아래. 둘이 겹칠 일이 없고 말풍선이 떠 있어도 서로 밀지 않는다.
        // pet 은 패널 바닥에 서 있으므로 패널 아래변에 꼬리 끝을 붙인다.
        hp.setFrameOrigin(NSPoint(x: petFrame.midX - size.width / 2,
                                  y: petFrame.minY - size.height))
        hp.orderFrontRegardless()
    }

    private func hideHoverCallout() {
        hoverPanel?.orderOut(nil)
        hoverPanel?.contentView = nil
    }

    private func makeHoverPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        return p
    }

    /// 지금 떠 있는 말풍선이 요구하는 여유 높이.
    private func currentHeadroom(petSize: CGFloat) -> CGFloat {
        Self.headroom(for: store.currentBubble, petSize: petSize)
    }

    private func targetFrame(petSize: CGFloat, headroom: CGFloat) -> NSRect {
        let size = Self.panelSize(petSize: petSize, headroom: headroom)
        let petOrigin: NSPoint
        if let x = defaults.object(forKey: Self.originXKey) as? Double,
           let y = defaults.object(forKey: Self.originYKey) as? Double {
            petOrigin = NSPoint(x: x, y: y)
        } else {
            petOrigin = Self.defaultPetOrigin(petSize: petSize)
        }
        var frame = NSRect(origin: Self.panelOrigin(petOrigin: petOrigin, petSize: petSize, panelSize: size),
                           size: size)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            let fallbackPet = Self.defaultPetOrigin(petSize: petSize)
            frame.origin = Self.panelOrigin(petOrigin: fallbackPet, petSize: petSize, panelSize: size)
        }
        return frame
    }

    private static func defaultPetOrigin(petSize: CGFloat) -> NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return NSPoint(x: 120, y: 120) }
        return NSPoint(x: visible.maxX - petSize - 24, y: visible.minY + 24)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.allowsToolTipsWhenApplicationIsInactive = true
        p.animationBehavior = .none
        p.delegate = self
        return p
    }

    func windowDidMove(_ notification: Notification) {
        guard let p = panel, p.isVisible else { return }
        let petSize = CGFloat(store.floatingPetSize)
        let size = Self.panelSize(petSize: petSize, headroom: currentHeadroom(petSize: petSize))
        let pet = Self.petOrigin(panelOrigin: p.frame.origin, petSize: petSize, panelSize: size)
        defaults.set(Double(pet.x), forKey: Self.originXKey)
        defaults.set(Double(pet.y), forKey: Self.originYKey)
        if hoverPanel?.isVisible == true { showHoverCallout() }
    }
}

final class PetHostingView: NSHostingView<AnyView> {
    var onOpenPopover: (() -> Void)?
    var onHide: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var languageProvider: () -> AppLanguage = { .systemDefault }

    private var mouseDownScreen: NSPoint?
    private var originAtDown: NSPoint?
    private var didDrag = false

    override var mouseDownCanMoveWindow: Bool { false }

    static func isClick(from start: NSPoint, to end: NSPoint,
                        thresholdSquared: CGFloat = FloatingPetController.clickThresholdSquared) -> Bool {
        FloatingPetController.isClick(from: start, to: end, thresholdSquared: thresholdSquared)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(event)
            return
        }
        mouseDownScreen = NSEvent.mouseLocation
        originAtDown = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = mouseDownScreen, let origin = originAtDown else { return }
        let now = NSEvent.mouseLocation
        if !Self.isClick(from: start, to: now) { didDrag = true }
        window.setFrameOrigin(NSPoint(x: origin.x + (now.x - start.x),
                                      y: origin.y + (now.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownScreen = nil
            originAtDown = nil
            didDrag = false
        }
        guard !didDrag, let start = mouseDownScreen else { return }
        if Self.isClick(from: start, to: NSEvent.mouseLocation) {
            onOpenPopover?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(event)
    }

    private func showContextMenu(_ event: NSEvent) {
        onHoverChange?(false)
        NSApp.activate(ignoringOtherApps: true)
        let l = L(languageProvider())
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        let open = menu.addItem(withTitle: l.floatingPetMenuOpen,
                                action: #selector(handleOpen(_:)), keyEquivalent: "")
        open.target = self
        open.isEnabled = true
        let hide = menu.addItem(withTitle: l.floatingPetMenuHide,
                                action: #selector(handleHide(_:)), keyEquivalent: "")
        hide.target = self
        hide.isEnabled = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func handleOpen(_ sender: Any?) { onOpenPopover?() }
    @objc func handleHide(_ sender: Any?) { onHide?() }
}

@MainActor
struct FloatingPetView: View {
    var animated: Bool = true
    @Environment(UsageStore.self) private var store
    @Environment(CompanionStore.self) private var companion

    var body: some View {
        let size = CGFloat(store.floatingPetSize)
        let subject = companion.representativeSubject
        VStack(spacing: 8) {
            if let bubble = store.currentBubble {
                SpeechBubbleView(content: bubble)
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }

            SpriteView(speciesID: subject.speciesID, size: size, animated: animated,
                       shiny: subject.isShiny,
                       minFrameDelay: store.animationQuality.frameFloor, unownForm: subject.unownForm)
                .frame(width: size, height: size)
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(animated ? .spring(response: 0.3, dampingFraction: 0.7) : nil,
                   value: store.currentBubble)
    }

    /// 툴팁 한 줄 — 이름과 사용률. used/remaining 변환과 막대 그리기는 뷰가 한다.
    struct LimitRow: Equatable, Identifiable {
        /// 한도는 남은 양으로 뒤집어 볼 수 있지만 경험치는 늘 쌓인 양이다. 뷰가 이걸로 갈라진다.
        enum Kind { case limit, experience }
        let label: String
        let percent: Double
        var kind: Kind = .limit
        var id: String { label }
    }

    /// 툴팁에 올릴 한도 줄들: 5시간 세션, 주간, 모델별 주간 순서. 값이 없는 줄은 빼고
    /// 순서는 유지한다 — 빈 자리를 0% 로 채우지 않는다.
    static func hoverLimitRows(sessionPercent: Double?, weeklyPercent: Double?,
                               modelWeeklyPercent: Double?, modelName: String,
                               experiencePercent: Double?, l: L) -> [LimitRow] {
        var rows: [LimitRow] = []
        if let sessionPercent { rows.append(LimitRow(label: l.fiveHourSession, percent: sessionPercent)) }
        if let weeklyPercent { rows.append(LimitRow(label: l.weekly, percent: weeklyPercent)) }
        if let modelWeeklyPercent {
            rows.append(LimitRow(label: "\(modelName) \(l.weekly)", percent: modelWeeklyPercent))
        }
        // 경험치는 한도가 아니라 펫 자신의 값이라 맨 아래에 둔다.
        if let experiencePercent {
            rows.append(LimitRow(label: l.expLabel, percent: experiencePercent, kind: .experience))
        }
        return rows
    }

    /// 같은 내용의 글자판. macOS 기본 툴팁처럼 막대를 그릴 수 없는 자리에서 쓴다.
    /// 아직 한도를 못 받았으면 오늘 토큰으로 되돌아간다 — 빈 툴팁을 만들지 않는다.
    static func hoverTooltip(rows: [LimitRow], todayTokens: Int,
                             mode: UsageStore.LimitDisplayMode, l: L) -> UsageStore.BubbleContent {
        guard !rows.isEmpty else {
            return UsageStore.BubbleContent(
                title: l.floatingPetHoverTokensOnly(TokenFormatter.grouped(todayTokens)), body: "")
        }
        let lines = rows.map { row in
            let value = row.kind == .limit
                ? percentText(row.percent, mode: mode, l: l)
                : TokenFormatter.percent(row.percent)
            return "\(row.label) \(value)"
        }
        return UsageStore.BubbleContent(title: l.statusTitle, body: lines.joined(separator: "\n"))
    }

    /// 사용률 표시 문자열. remaining 모드는 %를 뒤집고 자기설명 접미사를 붙인다.
    static func percentText(_ value: Double, mode: UsageStore.LimitDisplayMode, l: L) -> String {
        let text = TokenFormatter.percent(UsageStore.displayPercent(value, mode: mode))
        return mode == .remaining ? l.percentRemaining(text) : text
    }
}

/// 호버 콜아웃의 내용 — 제목 한 줄과 한도 줄들. 각 줄은 이름, 막대, 수치 순서다.
/// 수치 왼쪽에 막대를 두어 숫자를 읽기 전에 남은 양이 눈에 들어온다.
@MainActor
private struct HoverCalloutContent: View {
    let header: PetHeader
    let content: UsageStore.BubbleContent
    let rows: [FloatingPetView.LimitRow]
    let mode: UsageStore.LimitDisplayMode
    let l: L
    @Environment(UsageStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PetHeaderView(header: header)
            // 한도를 아직 못 받았으면 줄이 없다. 그 자리에 오늘 토큰을 대신 보여준다.
            if rows.isEmpty {
                Text(content.title)
                    .font(.system(size: FloatingPetController.bubbleBodyFontSize))
            }
            // 줄마다 HStack 을 쓰면 이름과 수치의 폭이 달라 막대와 숫자가 줄마다 어긋난다.
            // Grid 가 세 열의 폭을 함께 정한다.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(rows) { row in
                    // 한 식에 몰아넣으면 타입 추론이 ForEach 의 다른 오버로드로 새어 컴파일이 깨진다.
                    let isLimit = row.kind == .limit
                    let tint: Color = isLimit
                        ? LimitProgressBar.tint(row.percent, store: store) : .orange
                    let value = isLimit
                        ? FloatingPetView.percentText(row.percent, mode: mode, l: l)
                        : TokenFormatter.percent(row.percent)
                    GridRow {
                        Text(row.label)
                        StatusBar(percent: isLimit ? store.limitDisplayPercent(row.percent)
                                                   : row.percent,
                                  tint: tint)
                        Text(value).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.system(size: FloatingPetController.bubbleBodyFontSize))
        }
        .fixedSize()
    }
}

/// 이름, 이로치 표시, 등급 배지와 그 아래 단계·성격 줄. 툴팁과 말풍선이 같은 그림을 쓴다.
private struct PetHeaderView: View {
    let header: PetHeader
    var titleColor: Color = .primary
    var subtitleColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(header.name)
                    .font(.system(size: FloatingPetController.bubbleTitleFontSize, weight: .bold))
                    .foregroundColor(titleColor)
                if header.isShiny { Text("✨").font(.system(size: 10)) }
                if let rarity = header.rarity, let label = header.rarityText {
                    Text(label.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(rarityColor(rarity)).foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            if !header.subtitle.isEmpty {
                Text(header.subtitle).font(.caption2).foregroundColor(subtitleColor)
            }
        }
    }
}

/// 툴팁의 막대. `ProgressView` 는 키 윈도우가 아닌 패널에서 비활성 컨트롤로 그려져 색이
/// 회색으로 죽는다. 도형으로 직접 그리면 창 상태와 무관하게 색이 나온다.
private struct StatusBar: View {
    static let size = CGSize(width: 56, height: 6)
    /// 0 부터 100 까지. 표시 모드 변환은 부르는 쪽이 끝내고 넘긴다.
    let percent: Double
    let tint: Color

    var body: some View {
        let filled = Self.size.width * min(1, max(0, percent / 100))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.15))
                .frame(width: Self.size.width, height: Self.size.height)
            Capsule().fill(tint).frame(width: filled, height: Self.size.height)
        }
    }
}

/// 말풍선 색. 시스템 색은 라이트·다크 모드를 따라가고, Claude 색은 두 모드에서 같은 값이다.
private extension UsageStore.BubbleContent {
    /// 농담 말풍선의 글자색. 본가 대화 상자처럼 크림색 바탕에 진한 갈색을 쓴다.
    static let jokeInk = Color(red: 59 / 255, green: 47 / 255, blue: 30 / 255)
    /// recap 말풍선의 글자색. 주황 바탕에 흰 글씨는 대비가 3:1 근처라, 본문까지 옅게 하면
    /// 읽기 어려워진다. 다른 말풍선처럼 80% 로 낮추지 않고 거의 흰색을 유지한다.
    static let claudeInk = Color.white

    var backgroundColor: Color {
        switch palette {
        case .system: return Color(nsColor: .windowBackgroundColor)
        case .claude: return Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)   // Claude 주황
        case .joke: return Color(red: 255 / 255, green: 244 / 255, blue: 214 / 255)
        // Dooray Messenger 아이콘의 주색. 흰 글씨와 대비가 6:1 이라 본문도 잘 읽힌다.
        case .dooray: return Color(red: 71 / 255, green: 87 / 255, blue: 196 / 255)
        }
    }

    var titleColor: Color {
        if isCritical { return .red }
        switch palette {
        case .system: return .primary
        case .claude, .dooray: return Self.claudeInk
        case .joke: return Self.jokeInk
        }
    }

    var bodyColor: Color {
        switch palette {
        case .system: return .primary.opacity(0.8)
        case .claude, .dooray: return Self.claudeInk.opacity(0.92)
        case .joke: return Self.jokeInk.opacity(0.8)
        }
    }

    /// 외곽선은 배경색과 무관하게 툴팁과 같다. 굵기도 색도 한 값이라 네 표면이 같은 테를 두른다.
    var borderColor: Color { Color(nsColor: .separatorColor) }
}

/// Transient bubble. Width is capped so copy wraps instead of clipping the panel.
@MainActor
private struct SpeechBubbleView: View {
    let content: UsageStore.BubbleContent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let header = content.header {
                // 펫이 말하는 말풍선은 툴팁과 같은 머리를 쓴다.
                PetHeaderView(header: header, titleColor: content.titleColor,
                              subtitleColor: content.bodyColor)
            } else {
                Text(content.title)
                    .font(.system(size: FloatingPetController.bubbleTitleFontSize, weight: .bold))
                    .foregroundColor(content.titleColor)
                    // 제목에 외부 문자열(대화방 이름·세션 이름)이 들어오므로 줄 수를 묶는다.
                    // 더 번지면 고정 높이인 bubbleHeadroom 을 넘어 말풍선 위가 잘린다.
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(content.body)
                .font(.system(size: FloatingPetController.bubbleBodyFontSize))
                // .secondary 는 옅어서 읽기 어렵고 제목과 같은 진하기는 구분이 안 된다.
                .foregroundColor(content.bodyColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: FloatingPetController.bubbleContentWidth, alignment: .leading)
        .padding(.horizontal, FloatingPetController.bubbleHorizontalPadding)
        .padding(.vertical, 6)
        // 꼬리가 들어갈 자리. 배경이 여기까지 덮으므로 전체 높이는 예전과 같다.
        .padding(.bottom, BubbleShape.tailSize.height)
        .background(
            BubbleShape()
                .fill(content.backgroundColor)
                // 툴팁은 패널의 창 그림자를 쓴다. 말풍선은 패널 그림자를 끈 상태라 직접 그리는데,
                // 넓고 옅게 퍼뜨리면 경계가 흐려져 테두리가 없어 보인다. 좁고 진하게 맞춘다.
                .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)
        )
        // strokeBorder 는 선을 도형 안쪽에 그린다. stroke 는 경계에 걸쳐 그려서
        // 말풍선 폭이 패널 폭과 같은 좌우에서 바깥 절반이 창 밖으로 잘렸다.
        .overlay(BubbleShape().strokeBorder(content.borderColor,
                                            lineWidth: FloatingPetController.bubbleBorderWidth))
    }
}

/// 말풍선 윤곽 — 둥근 사각형과 바닥 가운데 꼬리를 한 줄기로 그린다. 둘을 따로 그리면
/// 외곽선이 꼬리 밑변을 가로지른다(호버 툴팁의 `HoverCalloutView` 와 같은 이유).
/// 꼬리가 가운데인 것은 말풍선과 pet 이 같은 VStack 의 가운데 정렬이라 그 가운데가
/// 곧 pet 의 중심이기 때문이다. 꼬리 끝이 pet 을 가리킨다.
private struct BubbleShape: InsettableShape {
    static let tailSize = CGSize(width: 12, height: 6)
    var cornerRadius: CGFloat = FloatingPetController.bubbleCornerRadius
    /// `strokeBorder` 가 선 굵기의 절반만큼 밀어 넣는 값.
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: rect.height - Self.tailSize.height)
        let half = Self.tailSize.width / 2
        let r = min(cornerRadius, min(body.width, body.height) / 2)
        var path = Path()
        // 모서리는 접선 호로 잇는다 — 각도와 회전 방향을 직접 계산하지 않아 좌표계를 헷갈릴 일이 없다.
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                    tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
        path.addLine(to: CGPoint(x: body.midX + half, y: body.maxY))
        path.addLine(to: CGPoint(x: body.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: body.midX - half, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                    tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
        path.closeSubpath()
        return path
    }
}

/// 호버 툴팁의 배경. 둥근 사각형과 아래쪽 꼬리를 한 줄기 외곽선으로 그린다 — 둘을 따로 그리면
/// 꼬리 밑변에 실선이 남는다. 말풍선(`BubbleTail`)과 같은 12x6 꼬리를 바닥 가운데에 둔다.
private final class HoverCalloutView: NSView {
    static let tailSize = NSSize(width: 12, height: 6)
    private let radius = FloatingPetController.bubbleCornerRadius

    var background: NSColor = .clear
    var border: NSColor = .clear

    override func draw(_ dirtyRect: NSRect) {
        // 툴팁은 pet 아래에 서므로 꼬리가 위를 향한다. 말풍선은 위에 서고 꼬리가 아래를 향한다.
        // 0.5 를 안쪽으로 밀어 0.5pt 외곽선이 뷰 경계에서 잘리지 않게 한다.
        let body = NSRect(x: bounds.minX + 0.5, y: bounds.minY + 0.5,
                          width: bounds.width - 1, height: bounds.height - Self.tailSize.height - 1)
        let half = Self.tailSize.width / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: body.minX + radius, y: body.minY))
        path.appendArc(withCenter: NSPoint(x: body.maxX - radius, y: body.minY + radius),
                       radius: radius, startAngle: 270, endAngle: 0)
        path.appendArc(withCenter: NSPoint(x: body.maxX - radius, y: body.maxY - radius),
                       radius: radius, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: body.midX + half, y: body.maxY))
        path.line(to: NSPoint(x: body.midX, y: bounds.maxY - 0.5))
        path.line(to: NSPoint(x: body.midX - half, y: body.maxY))
        path.appendArc(withCenter: NSPoint(x: body.minX + radius, y: body.maxY - radius),
                       radius: radius, startAngle: 90, endAngle: 180)
        path.appendArc(withCenter: NSPoint(x: body.minX + radius, y: body.minY + radius),
                       radius: radius, startAngle: 180, endAngle: 270)
        path.close()
        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = FloatingPetController.bubbleBorderWidth
        path.stroke()
    }
}
