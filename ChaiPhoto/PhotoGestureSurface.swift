import SwiftUI
import UIKit

struct PhotoGestureSurface: UIViewRepresentable {
    let onSingleTap: () -> Void
    let onDoubleTapCenter: () -> Void
    let onLongPress: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void
    let onSwipeUp: () -> Void
    let onCancelDrag: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.singleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.longPress(_:))
        )
        longPress.minimumPressDuration = 0.35

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.pan(_:))
        )

        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: longPress)

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        private enum DragAxis {
            case horizontal
            case vertical
        }

        var parent: PhotoGestureSurface
        private var dragAxis: DragAxis?

        init(parent: PhotoGestureSurface) {
            self.parent = parent
        }

        @objc func singleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            parent.onSingleTap()
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let centerRange = (view.bounds.width * 0.25)...(view.bounds.width * 0.75)
            guard centerRange.contains(point.x) else { return }
            parent.onDoubleTapCenter()
        }

        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            parent.onLongPress()
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }

            let translation = gesture.translation(in: view.window)
            let velocity = gesture.velocity(in: view.window)

            switch gesture.state {
            case .began:
                dragAxis = nil

            case .changed:
                if dragAxis == nil {
                    let distance = hypot(translation.x, translation.y)
                    guard distance >= 10 else { return }
                    dragAxis = abs(translation.x) >= abs(translation.y)
                        ? .horizontal
                        : .vertical
                }

                switch dragAxis {
                case .horizontal:
                    parent.onDragChanged(
                        CGSize(width: translation.x, height: 0)
                    )
                case .vertical:
                    parent.onDragChanged(
                        CGSize(width: 0, height: translation.y)
                    )
                case nil:
                    break
                }

            case .ended:
                defer { dragAxis = nil }

                let axis =
                    dragAxis ??
                    (abs(translation.x) >= abs(translation.y)
                        ? .horizontal
                        : .vertical)

                // Push the exact finger-up position first. UIKit's final
                // translation can be newer than SwiftUI's last .changed sample.
                switch axis {
                case .horizontal:
                    parent.onDragChanged(
                        CGSize(width: translation.x, height: 0)
                    )

                    let distanceThreshold =
                        min(max(view.bounds.width * 0.16, 55), 82)
                    let projectedX =
                        translation.x + velocity.x * 0.18
                    let commit =
                        abs(translation.x) >= distanceThreshold ||
                        abs(projectedX) >= max(
                            distanceThreshold * 1.35,
                            92
                        )

                    guard commit else {
                        parent.onCancelDrag()
                        return
                    }

                    let directionSource =
                        abs(projectedX) > abs(translation.x)
                            ? projectedX
                            : translation.x

                    // Start the dismissal on the next main-loop turn so the last
                    // finger-controlled frame is rendered before SwiftUI animates.
                    DispatchQueue.main.async {
                        if directionSource < 0 {
                            self.parent.onSwipeLeft()
                        } else {
                            self.parent.onSwipeRight()
                        }
                    }

                case .vertical:
                    parent.onDragChanged(
                        CGSize(width: 0, height: translation.y)
                    )

                    let projectedY =
                        translation.y + velocity.y * 0.16
                    let swipeUp =
                        translation.y <= -55 ||
                        projectedY <= -90

                    if swipeUp {
                        DispatchQueue.main.async {
                            self.parent.onSwipeUp()
                        }
                    } else {
                        parent.onCancelDrag()
                    }
                }

            case .cancelled, .failed:
                dragAxis = nil
                parent.onCancelDrag()

            default:
                break
            }
        }
    }
}
