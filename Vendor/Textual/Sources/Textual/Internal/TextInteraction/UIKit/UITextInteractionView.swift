#if TEXTUAL_ENABLE_TEXT_SELECTION && canImport(UIKit)
  import SwiftUI
  import os
  import UniformTypeIdentifiers

  // MARK: - Overview
  //
  // `UITextInteractionView` implements selection and link interaction on iOS-family platforms.
  //
  // The view sits in an overlay above one or more rendered `Text` fragments. It uses
  // `TextSelectionModel` to translate touch locations into URLs and selection ranges, and it
  // respects `exclusionRects` so embedded scrollable regions can continue to handle gestures.
  // Selection UI is provided by `UITextInteraction` configured for non-editable content.

  final class UITextInteractionView: UIView {
    override var canBecomeFirstResponder: Bool {
      true
    }

    var model: TextSelectionModel
    var exclusionRects: [CGRect]
    var openURL: OpenURLAction

    /// Message-level actions injected by the app shell and shown in the system
    /// edit menu alongside Copy. This is how a chat client keeps "copy all /
    /// edit / regenerate" reachable without a SwiftUI `.contextMenu`, which
    /// would steal the long-press gesture from UITextInteraction and make
    /// partial text selection impossible.
    var menuActions: TextMenuActions?

    weak var inputDelegate: (any UITextInputDelegate)?

    let logger = Logger(category: .textInteraction)

    private(set) lazy var _tokenizer = UITextInputStringTokenizer(textInput: self)
    private let selectionInteraction: UITextInteraction

    init(
      model: TextSelectionModel,
      exclusionRects: [CGRect],
      openURL: OpenURLAction
    ) {
      self.model = model
      self.exclusionRects = exclusionRects
      self.openURL = openURL
      self.selectionInteraction = UITextInteraction(for: .nonEditable)

      super.init(frame: .zero)
      self.backgroundColor = .clear

      setUp()
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      for exclusionRect in exclusionRects {
        if exclusionRect.contains(point) {
          return false
        }
      }
      return super.point(inside: point, with: event)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      switch action {
      case #selector(copy(_:)), #selector(share(_:)):
        return !(model.selectedRange?.isCollapsed ?? true)
      default:
        return super.canPerformAction(action, withSender: sender)
      }
    }

    override func copy(_ sender: Any?) {
      guard let selectedRange = model.selectedRange else {
        return
      }

      let attributedText = model.attributedText(in: selectedRange)
      let formatter = Formatter(attributedText)

      UIPasteboard.general.setItems(
        [
          [
            UTType.plainText.identifier: formatter.plainText(),
            UTType.html.identifier: formatter.html(),
          ]
        ]
      )
    }

    private func setUp() {
      model.selectionWillChange = { [weak self] in
        guard let self else { return }
        self.inputDelegate?.selectionWillChange(self)
      }
      model.selectionDidChange = { [weak self] in
        guard let self else { return }
        self.inputDelegate?.selectionDidChange(self)
      }

      let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      addGestureRecognizer(tapGesture)

      selectionInteraction.textInput = self
      selectionInteraction.delegate = self

      for gesture in selectionInteraction.gesturesForFailureRequirements {
        tapGesture.require(toFail: gesture)
      }

      addInteraction(selectionInteraction)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
      let location = gesture.location(in: self)
      guard let url = model.url(for: location) else {
        model.selectedRange = nil
        return
      }
      openURL(url)
    }

    @objc private func share(_ sender: Any?) {
      guard let selectedRange = model.selectedRange else {
        return
      }

      let attributedText = model.attributedText(in: selectedRange)
      let itemSource = TextActivityItemSource(attributedString: attributedText)

      let activityViewController = UIActivityViewController(
        activityItems: [itemSource],
        applicationActivities: nil
      )

      if let popover = activityViewController.popoverPresentationController {
        let rect =
          model.selectionRects(for: selectedRange)
          .last?.rect.integral ?? .zero
        popover.sourceView = self
        popover.sourceRect = rect
      }

      if let windowScene = window?.windowScene,
        let viewController = windowScene.windows.first?.rootViewController
      {
        viewController.present(activityViewController, animated: true)
      }
    }
  }

  extension UITextInteractionView: UITextInteractionDelegate {
    func interactionShouldBegin(_ interaction: UITextInteraction, at point: CGPoint) -> Bool {
      // Initial/removed layouts have no valid document positions yet.
      // Once the delivery view installs a populated layout, selection may start.
      logger.debug("interactionShouldBegin(at: \(point.logDescription)) hasText=\(self.model.hasText)")
      return model.hasText
    }

    func interactionWillBegin(_ interaction: UITextInteraction) {
      logger.debug("interactionWillBegin")
      _ = self.becomeFirstResponder()
    }

    func interactionDidEnd(_ interaction: UITextInteraction) {
      logger.debug("interactionDidEnd")
    }

    /// Extend the system edit menu with message-level actions. Falls back to
    /// the default menu when the app shell provided no actions.
    func editMenu(
      for textRange: UITextRange,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      var children = suggestedActions
      if let copyAll = menuActions?.copyAll {
        children.append(
          UIAction(title: "复制全文", image: UIImage(systemName: "doc.on.doc")) { _ in
            copyAll()
          }
        )
      }
      if let edit = menuActions?.edit {
        children.append(
          UIAction(title: "编辑并在分支发送", image: UIImage(systemName: "pencil")) { _ in
            edit()
          }
        )
      }
      if let regenerate = menuActions?.regenerate {
        children.append(
          UIAction(title: "在分支重新生成", image: UIImage(systemName: "arrow.clockwise")) { _ in
            regenerate()
          }
        )
      }
      return UIMenu(children: children)
    }
  }

  extension Logger.Textual.Category {
    fileprivate static let textInteraction = Self(rawValue: "textInteraction")
  }
#endif
