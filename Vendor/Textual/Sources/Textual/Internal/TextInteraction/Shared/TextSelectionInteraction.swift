import SwiftUI

// MARK: - Overview
//
// `TextSelectionInteraction` manages the text selection model lifecycle for multiple `Text` fragments.
//
// Selection is opt-in through the `textSelection` environment value. When enabled, the modifier
// observes text layout changes via `overlayTextLayoutCollection` and creates or updates a
// `TextSelectionModel`. The model is then passed to the platform-specific implementation
// (`PlatformTextSelectionInteraction`), which presents the appropriate selection UI for macOS
// or iOS. This separation keeps model management in shared code while platform interactions
// remain independent.

struct TextSelectionInteraction: ViewModifier {
  #if TEXTUAL_ENABLE_TEXT_SELECTION
    @Environment(\.textSelection) private var textSelection
    @Environment(TextSelectionCoordinator.self) private var coordinator: TextSelectionCoordinator?
    @Environment(\.textualTextMenuActions) private var menuActions: TextMenuActions?

    @State private var model = TextSelectionModel()
  #endif

  func body(content: Content) -> some View {
    #if TEXTUAL_ENABLE_TEXT_SELECTION
      if textSelection.allowsSelection {
        content
          .overlayTextLayoutCollection { layoutCollection in
            #if canImport(UIKit)
              TextSelectionLayoutUpdater(model: model, coordinator: coordinator,
                                         layoutCollection: layoutCollection)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            #else
            Color.clear
              .onChange(of: AnyTextLayoutCollection(layoutCollection), initial: true) {
                model.setCoordinator(coordinator)
                model.setLayoutCollection(layoutCollection)
              }
            #endif
          }
          .modifier(PlatformTextSelectionInteraction(model: model, menuActions: menuActions))
      } else {
        content
      }
    #else
      content
    #endif
  }
}

#if TEXTUAL_ENABLE_TEXT_SELECTION
  extension EnvironmentValues {
    @available(tvOS, unavailable)
    @available(watchOS, unavailable)
    @usableFromInline
    @Entry var textSelection: any TextSelectability.Type = DisabledTextSelectability.self

    /// Message-level actions (copy all / edit / regenerate) surfaced in the
    /// system edit menu when text is selected. The app shell sets this on the
    /// markdown view; `TextMenuActions` is a reference type so the environment
    /// value stays identity-comparable.
    @available(tvOS, unavailable)
    @available(watchOS, unavailable)
    @Entry public var textualTextMenuActions: TextMenuActions? = nil
  }
#endif

/// Message-level actions shown in the system text-selection edit menu.
public final class TextMenuActions {
  public var copyAll: (() -> Void)?
  public var edit: (() -> Void)?
  public var regenerate: (() -> Void)?

  public init(
    copyAll: (() -> Void)? = nil,
    edit: (() -> Void)? = nil,
    regenerate: (() -> Void)? = nil
  ) {
    self.copyAll = copyAll
    self.edit = edit
    self.regenerate = regenerate
  }
}
