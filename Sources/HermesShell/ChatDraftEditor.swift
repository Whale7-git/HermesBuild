import SwiftUI
import UIKit

/// 输入框当前暴露的行数信息：可见行数（受 6 行/3 行封顶约束）与内容是否已溢出。
struct ChatDraftMetrics: Equatable {
    var visibleLines: Int
    var isScrollable: Bool
}

/// A real multiline UIKit input client. The return-key trait is visible to
/// system/custom keyboards; the app does not select or replace their layouts.
struct ChatDraftEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let editable: Bool
    let returnSends: Bool
    let canSubmit: Bool
    let onSubmit: () -> Void
    let onComposition: (Bool) -> Void
    var onInputEvent: ((String) -> Void)? = nil
    /// 行数/溢出变化回调（可选）。调用方不传时行为完全不变。
    var onMetricsChange: ((ChatDraftMetrics) -> Void)? = nil
    /// UTF-16 caret offset for slash-command discovery. The parent sends a
    /// replacement token when a suggestion is selected.
    var onSelectionChange: ((Int) -> Void)? = nil
    var commandInsertion: ChatDraftCommandInsertion? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ChatDraftTextView {
        let view = ChatDraftTextView()
        view.delegate = context.coordinator
        view.onMetricsChange = { [weak coordinator = context.coordinator] metrics in
            coordinator?.parent.onMetricsChange?(metrics)
        }
        view.onWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.synchronizeFocus(view)
        }
        return view
    }

    func updateUIView(_ view: ChatDraftTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applying = true
        defer { context.coordinator.applying = false }
        if view.isEditable != editable { view.isEditable = editable }
        let key: UIReturnKeyType = returnSends ? .send : .default
        if view.returnKeyType != key {
            view.returnKeyType = key
            if view.isFirstResponder { view.reloadInputViews() }
        }
        // Never replace the document while an IME owns marked text. In
        // particular, a SwiftUI publication must not cancel Chinese candidates.
        if view.markedTextRange == nil, view.text != text {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            view.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            view.refresh()
        }
        context.coordinator.synchronizeFocus(view)
        context.coordinator.applyCommandInsertion(view, request: commandInsertion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatDraftTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width >= 44 else { return nil }
        return CGSize(width: width, height: uiView.fittingHeight(width: width))
    }

    static func dismantleUIView(_ view: ChatDraftTextView, coordinator: Coordinator) {
        coordinator.active = false
        view.delegate = nil
        view.onWindow = nil
        view.resignFirstResponder()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatDraftEditor
        var active = true
        var applying = false
        private var lastComposing = false
        private var focusScheduled = false
        private var returnScheduled = false
        private var appliedCommandToken: Int?
        init(_ parent: ChatDraftEditor) { self.parent = parent }

        func synchronizeFocus(_ view: ChatDraftTextView) {
            // Most SwiftUI composer updates do not change keyboard intent.
            // Avoid queueing a main-thread focus job for every keystroke and
            // text-layout callback when UIKit is already in the requested state.
            guard view.window != nil else { return }
            let wantsFocus = parent.focused && parent.editable
            guard view.isFirstResponder != wantsFocus, !focusScheduled else { return }
            // Becoming first responder can synchronously invoke UIKit delegates.
            // Hop out of SwiftUI's update pass and re-check the latest intention.
            focusScheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.active, let view, view.window != nil else { return }
                if self.parent.focused && self.parent.editable {
                    if !view.isFirstResponder { view.becomeFirstResponder() }
                } else if view.isFirstResponder { view.resignFirstResponder() }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard !applying else { return }
            let mode = textView.returnKeyType == .send ? "send" : "default"
            parent.onInputEvent?("开始输入 · returnKey=\(mode)")
            publish(textView)
            if !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onInputEvent?("结束输入")
            if applying {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, self.active, let textView, !textView.isFirstResponder else { return }
                    self.publish(textView)
                    if self.parent.focused { self.parent.focused = false }
                }
                return
            }
            publish(textView)
            if parent.focused { parent.focused = false }
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? ChatDraftTextView)?.refresh()
            publish(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) { publish(textView) }

        func applyCommandInsertion(_ view: ChatDraftTextView,
                                   request: ChatDraftCommandInsertion?) {
            guard let request, appliedCommandToken != request.token else { return }
            appliedCommandToken = request.token
            guard view.markedTextRange == nil else {
                // Retry once the IME releases marked text; do not discard the user's
                // current candidates or apply a stale suggestion.
                appliedCommandToken = nil
                return
            }
            view.text = request.text
            let end = (request.text as NSString).length
            view.selectedRange = NSRange(location: end, length: 0)
            view.refresh()
            publish(view)
            parent.onSelectionChange?(end)
        }

        private func publish(_ view: UITextView) {
            guard active, !applying else { return }
            let composing = view.markedTextRange != nil
            if composing != lastComposing {
                lastComposing = composing
                parent.onComposition(composing)
            }
            if !composing, parent.text != view.text { parent.text = view.text ?? "" }
            parent.onSelectionChange?(view.selectedRange.location)
        }

        func returnRequested() {
            // Leave UIKit's editing callback before changing the transcript.
            guard active, !returnScheduled else { return }
            returnScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.returnScheduled = false
                guard self.active, self.parent.editable, self.parent.canSubmit,
                      !self.lastComposing else { return }
                self.parent.onSubmit()
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            shouldEdit(textView, replacement: text, origin: "单区间")
        }

        @available(iOS 26.0, *)
        func textView(_ textView: UITextView, shouldChangeTextInRanges ranges: [NSValue],
                      replacementText text: String) -> Bool {
            shouldEdit(textView, replacement: text, origin: "多区间")
        }

        private func shouldEdit(_ textView: UITextView, replacement: String, origin: String) -> Bool {
            guard let view = textView as? ChatDraftTextView else { return true }
            publish(view)
            let action = ChatInputPolicy.action(replacement: replacement,
                isReturnAction: !view.insertingDocumentText,
                composing: view.markedTextRange != nil || view.isWritingToolsActive,
                returnSends: parent.returnSends, canSubmit: parent.canSubmit)
            // Test page only; never record ordinary input or message contents.
            if let report = parent.onInputEvent, !replacement.isEmpty,
               replacement.unicodeScalars.count <= 4,
               replacement.unicodeScalars.allSatisfy({ [10, 13, 0x2028, 0x2029].contains($0.value) }) {
                let codes = replacement.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
                let result: String
                switch action {
                case .submit: result = "发送"
                case .consume: result = "忽略（当前不能发送）"
                case .edit: result = "插入换行"
                }
                report("\(origin) · \(codes) · \(result)")
            }
            switch action {
            case .submit: returnRequested(); return false
            case .consume: return false
            case .edit: return true
            }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let newline = UIAction(title: "换行", image: UIImage(systemName: "return")) { [weak textView] _ in
                guard let view = textView as? ChatDraftTextView, view.isEditable,
                      view.markedTextRange == nil else { return }
                view.insertExplicitNewline()
            }
            return UIMenu(children: suggestedActions + [newline])
        }
    }
}

struct ChatDraftCommandInsertion: Equatable {
    var token: Int
    var text: String
}

final class ChatDraftTextView: UITextView {
    var onWindow: (() -> Void)?
    var onMetricsChange: ((ChatDraftMetrics) -> Void)?
    private(set) var insertingDocumentText = false
    private let placeholder = UILabel()
    private var previousWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0
    private var measuredText = ""
    private var measuredFont: UIFont?
    private var measuredCategory: UIContentSizeCategory?
    private var measuredMetrics: ChatDraftMetrics?
    private var reportedMetrics: ChatDraftMetrics?

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        font = .preferredFont(forTextStyle: .body)
        textColor = .label
        tintColor = UIColor(AppTheme.accent)
        adjustsFontForContentSizeCategory = true
        keyboardType = .default
        returnKeyType = .send
        enablesReturnKeyAutomatically = false // attachment-only sends remain possible
        isSecureTextEntry = false
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        scrollsToTop = false
        contentInsetAdjustmentBehavior = .never
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholder.text = "给 Hermes 发消息"
        placeholder.textColor = .placeholderText
        placeholder.font = font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
        accessibilityLabel = "消息输入框"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindow?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.font = font
        placeholder.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                   height: ceil(font?.lineHeight ?? 22))
        placeholder.isHidden = !(text ?? "").isEmpty
        let pixelWidth = CGFloat(ChatDraftWidthPolicy.canonical(
            Double(bounds.width), scale: Double(traitCollection.displayScale)))
        if previousWidth != pixelWidth {
            previousWidth = pixelWidth
            invalidateIntrinsicContentSize()
        }
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        let line = ceil(font?.lineHeight ?? 22)
        // Match UIKit/SwiftUI proposals at device-pixel precision, including
        // the layoutSubviews width-change check. Never round upward by more
        // than half a pixel when asking TextKit to wrap the same document.
        let measuredWidth = CGFloat(ChatDraftWidthPolicy.canonical(
            Double(width), scale: Double(traitCollection.displayScale)))
        // An unresolved intrinsic/proposed width is not usable for text
        // wrapping. Returning a one-line provisional height avoids the
        // early 1pt-width "100 lines" measurement and feedback cycle.
        guard measuredWidth >= 44 else { return line }
        let value = text ?? ""
        // Pure read: safe to call from layoutSubviews / sizeThatFits.
        let category = traitCollection.preferredContentSizeCategory
        if measuredHeight > 0, self.measuredWidth == measuredWidth, measuredText == value,
           measuredFont == font, measuredCategory == category,
           let cached = measuredMetrics {
            syncMetrics(cached, width: measuredWidth)
            return measuredHeight
        }
        // Empty UITextView may report an old multiline height after a
        // UIKit/SwiftUI reuse pass. Ignore that stale size for blank drafts.
        let natural: CGFloat = value.isEmpty ? line :
            super.sizeThatFits(CGSize(width: measuredWidth, height: .greatestFiniteMagnitude)).height
        // 6 行在 AX 字号下会吞掉整屏，按内容尺寸类别收紧可见行数。
        // 行数必须先取整到整数，再由它反推高度。
        //
        // 原实现是 `height = min(maxLines * line, ceil(natural))`、
        // `visibleLines = Int(min(maxLines, max(1, (visible / line).rounded(.up))))`
        // ——高度用连续值、行数再从高度反算。浮点误差会让「2 行整」算成
        // 2.0000001 而进到 3 行：行数变化写回 SwiftUI `@State`，触发重排，
        // 重排又把宽度微调回去，于是行数在 2/3 之间反复，输入多行时一直抖。
        // 改成先定整数行数、高度只由这个整数算，两端用同一个值，不会来回。
        let lines = ChatDraftHeightPolicy.lines(
            naturalHeight: Double(natural), lineHeight: Double(line),
            accessibility: category.isAccessibilityCategory)
        let visible = CGFloat(ChatDraftHeightPolicy.height(
            lines: lines, lineHeight: Double(line)))
        let height = max(line, visible)
        let metrics = ChatDraftMetrics(visibleLines: lines,
                                       isScrollable: natural > visible + 0.5)
        measuredHeight = height
        self.measuredWidth = measuredWidth
        measuredText = value
        measuredFont = font
        measuredCategory = category
        measuredMetrics = metrics
        syncMetrics(metrics, width: measuredWidth)
        return height
    }

    /// 内容超过可见行数时允许滚动；**不打开滚动条**。
    ///
    /// 打开滚动条会占掉若干点宽度 → 换行点变化 → 高度变化 → 又一次布局，
    /// 输入多行时表现为持续抖动。滚动能力靠 `isScrollEnabled`（始终开）
    /// 就够，滚动条本身对一屏 6 行的输入框没有价值。
    private func syncMetrics(_ metrics: ChatDraftMetrics, width: CGFloat) {
        guard width > 20 else { return }
        guard reportedMetrics != metrics else { return }
        reportedMetrics = metrics
        // UIKit may ask sizeThatFits from a SwiftUI update transaction.
        // Never synchronously mutate parent @State during that measurement.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedMetrics == metrics else { return }
            self.onMetricsChange?(metrics)
        }
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width
        let provisional = ceil(font?.lineHeight ?? 22)
        return CGSize(width: UIView.noIntrinsicMetric,
            height: width.isFinite && width >= 44
                ? fittingHeight(width: width) : provisional)
    }

    func refresh() {
        placeholder.isHidden = !(text ?? "").isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func paste(_ sender: Any?) {
        // A pasted single LF is document content, never a keyboard Send action.
        insertingDocumentText = true
        defer { insertingDocumentText = false }
        super.paste(sender)
    }

    /// Hardware keyboards often deliver Option/Shift+Return as an editing
    /// command. Keep the send key's primary action, but let modified Return
    /// insert a real line break without dismissing the keyboard.
    override var keyCommands: [UIKeyCommand]? {
        let modifiers: [UIKeyModifierFlags] = [.shift, .alternate]
        let commands = modifiers.map {
            UIKeyCommand(title: "换行", action: #selector(insertHardwareNewline),
                         input: "\r", modifierFlags: $0)
        }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func insertHardwareNewline() {
        guard isEditable, markedTextRange == nil else { return }
        insertExplicitNewline()
    }

    func insertExplicitNewline() {
        guard let range = selectedTextRange else { return }
        let location = offset(from: beginningOfDocument, to: range.start)
        let previous = insertingDocumentText
        insertingDocumentText = true
        replace(range, withText: "\n")
        if let caret = position(from: beginningOfDocument, offset: location + 1) {
            selectedTextRange = textRange(from: caret, to: caret)
        }
        insertingDocumentText = previous
        refresh()
        delegate?.textViewDidChange?(self)
    }
}
