#if TEXTUAL_ENABLE_TEXT_SELECTION && canImport(UIKit)
  import SwiftUI

  /// Data delivery only. The actual UITextInteraction overlay remains the sole
  /// owner of selection gestures, links and edit menus.
  struct TextSelectionLayoutUpdater: UIViewRepresentable {
    let model: TextSelectionModel
    let coordinator: TextSelectionCoordinator?
    let layoutCollection: any TextLayoutCollection

    struct Update {
      let model: TextSelectionModel
      let coordinator: TextSelectionCoordinator?
      let layoutCollection: any TextLayoutCollection
    }

    final class DeliveryView: UIView {
      let relay = TextSelectionUpdateRelay<Update>()
    }

    func makeUIView(context: Context) -> DeliveryView {
      let view = DeliveryView(frame: .zero)
      view.isUserInteractionEnabled = false
      view.isAccessibilityElement = false
      view.backgroundColor = .clear
      return view
    }

    func updateUIView(_ uiView: DeliveryView, context: Context) {
      // Resolve geometry while its GeometryProxy belongs to this update, before
      // handing the immutable layout/origin snapshot to the deferred callback.
      _ = layoutCollection.layouts
      uiView.relay.submit(Update(model: model, coordinator: coordinator,
                                 layoutCollection: layoutCollection)) { value in
        value.model.setCoordinator(value.coordinator)
        value.model.setLayoutCollection(value.layoutCollection)
      }
    }

    static func dismantleUIView(_ uiView: DeliveryView, coordinator: ()) {
      uiView.relay.cancel()
    }
  }
#endif
