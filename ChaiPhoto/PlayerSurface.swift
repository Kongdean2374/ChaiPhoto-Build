import AVFoundation
import SwiftUI
import UIKit

final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer?
    let onReadyForDisplay: (Bool) -> Void
    let onSingleTap: () -> Void
    let onDoubleTapLeft: () -> Void
    let onDoubleTapCenter: () -> Void
    let onDoubleTapRight: () -> Void
    let onVerticalDrag: ((CGFloat) -> Void)?
    let onSwipeUp: (() -> Void)?
    let onSwipeDown: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        singleTap.require(toFail: doubleTap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.cancelsTouchesInView = true

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(pan)

        context.coordinator.observe(layer: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        context.coordinator.parent = self
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
            context.coordinator.observe(layer: view.playerLayer)
        }
    }

    static func dismantleUIView(_ view: PlayerLayerHostView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.playerLayer.player = nil
    }

    final class Coordinator: NSObject {
        var parent: PlayerSurface
        private var readyObservation: NSKeyValueObservation?

        init(parent: PlayerSurface) {
            self.parent = parent
        }

        func observe(layer: AVPlayerLayer) {
            stopObserving()
            readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                DispatchQueue.main.async {
                    self?.parent.onReadyForDisplay(layer.isReadyForDisplay)
                }
            }
        }

        func stopObserving() {
            readyObservation?.invalidate()
            readyObservation = nil
        }

        @objc func singleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            parent.onSingleTap()
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view.window)
            let velocity = gesture.velocity(in: view.window)

            guard abs(translation.y) > abs(translation.x) else {
                if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                    parent.onVerticalDrag?(0)
                }
                return
            }

            switch gesture.state {
            case .began, .changed:
                parent.onVerticalDrag?(translation.y)

            case .ended:
                // Keep the rendered video at the exact finger-up position before
                // starting the next animation. This avoids a one-frame hitch.
                parent.onVerticalDrag?(translation.y)

                let shouldCommit = abs(translation.y) > 80 || abs(velocity.y) > 700
                if shouldCommit {
                    DispatchQueue.main.async {
                        if translation.y < 0 || velocity.y < -700 {
                            self.parent.onSwipeUp?()
                        } else {
                            self.parent.onSwipeDown?()
                        }
                    }
                } else {
                    parent.onVerticalDrag?(0)
                }

            case .cancelled, .failed:
                parent.onVerticalDrag?(0)

            default:
                break
            }
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let third = view.bounds.width / 3

            if point.x < third {
                parent.onDoubleTapLeft()
            } else if point.x > third * 2 {
                parent.onDoubleTapRight()
            } else {
                parent.onDoubleTapCenter()
            }
        }
    }
}
