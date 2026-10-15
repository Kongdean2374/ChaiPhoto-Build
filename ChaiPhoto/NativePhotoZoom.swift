import SwiftUI
import Photos

/// UIScrollView supplies native pinch, pan, inertia and double-tap zoom.
struct NativePhotoZoom: UIViewRepresentable {
    let asset: PHAsset
    var onCloudUnavailable: (() -> Void)? = nil
    @EnvironmentObject private var settings: AppSettings

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        let view = PhotoZoomScrollView()
        view.onCloudUnavailable = onCloudUnavailable
        view.load(asset, allowNetwork: settings.canDownloadPhoto(for: asset.localIdentifier))
        return view
    }

    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        view.onCloudUnavailable = onCloudUnavailable
        if view.assetID != asset.localIdentifier || view.allowNetwork != settings.canDownloadPhoto(for: asset.localIdentifier) {
            view.load(asset, allowNetwork: settings.canDownloadPhoto(for: asset.localIdentifier))
        }
    }

    static func dismantleUIView(_ view: PhotoZoomScrollView, coordinator: ()) { view.cancel() }
}

final class PhotoZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let photo = UIImageView()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    var assetID = ""
    var allowNetwork = false
    var onCloudUnavailable: (() -> Void)?
    private var request: PHImageRequestID?
    private var generation = UUID()
    private var priorSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1; maximumZoomScale = 5
        bouncesZoom = true; showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        backgroundColor = .clear
        photo.contentMode = .scaleAspectFit
        photo.layer.borderWidth = 1
        addSubview(photo)
        status.numberOfLines = 0
        status.textAlignment = .center
        status.textColor = .label
        addSubview(status); addSubview(spinner)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2; addGestureRecognizer(doubleTap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdZoom(_:)))
        hold.minimumPressDuration = 0.3; addGestureRecognizer(hold)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func cancel() {
        generation = UUID()
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
    }
    func load(_ asset: PHAsset, allowNetwork: Bool) {
        let sameAsset = assetID == asset.localIdentifier
        cancel()
        assetID = asset.localIdentifier
        self.allowNetwork = allowNetwork

        if !sameAsset {
            photo.image = nil
            setZoomScale(1, animated: false)
        }

        status.text = nil
        spinner.startAnimating()
        let token = generation
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact

        request = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 4096, height: 4096),
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, info in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if info?[PHImageCancelledKey] as? Bool == true { return }
                if !allowNetwork && info?[PHImageResultIsInCloudKey] as? Bool == true {
                    self.onCloudUnavailable?()
                }
                guard let image else {
                    if info?[PHImageResultIsDegradedKey] as? Bool != true {
                        self.spinner.stopAnimating()
                        if self.photo.image != nil { return }
                        self.status.text = L("無法載入照片。請確認網路及設定中的 iCloud 照片下載權限，再重新開啟。", "Photo unavailable. Check your connection and iCloud photo download setting, then reopen.")
                    }
                    return
                }
                self.spinner.stopAnimating(); self.status.text = nil
                let hadImage = self.photo.image != nil
                UIView.transition(
                    with: self.photo,
                    duration: hadImage ? 0.16 : 0,
                    options: [.transitionCrossDissolve, .allowAnimatedContent]
                ) {
                    self.photo.image = image
                }
                self.fitImage(resetZoom: !sameAsset && !hadImage)
            }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        status.frame = CGRect(x: bounds.minX + 24, y: bounds.midY - 60, width: max(0, bounds.width - 48), height: 120)
        photo.layer.borderColor = (traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black).withAlphaComponent(0.8).cgColor
        if priorSize != bounds.size { priorSize = bounds.size; fitImage() }
        centerPhoto()
    }
    private func fitImage(resetZoom: Bool = true) {
        guard let image = photo.image, bounds.width > 0, bounds.height > 0 else { return }
        let savedZoom = resetZoom ? 1 : zoomScale
        let normalizedCenter = CGPoint(
            x: (contentOffset.x + bounds.width / 2) / max(1, contentSize.width),
            y: (contentOffset.y + bounds.height / 2) / max(1, contentSize.height))
        // frame is only well-defined while the zoom transform is identity.
        setZoomScale(1, animated: false)
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        photo.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
        contentSize = photo.bounds.size
        setZoomScale(savedZoom, animated: false)
        centerPhoto()
        if savedZoom > 1 {
            contentOffset = CGPoint(
                x: max(-contentInset.left, min(contentSize.width - bounds.width + contentInset.right, normalizedCenter.x * contentSize.width - bounds.width / 2)),
                y: max(-contentInset.top, min(contentSize.height - bounds.height + contentInset.bottom, normalizedCenter.y * contentSize.height - bounds.height / 2)))
        }
    }
    private func centerPhoto() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPhoto() }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.05 { setZoomScale(1, animated: true) }
        else { zoomAt(gesture.location(in: photo), scale: 2.5) }
    }
    @objc private func holdZoom(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { zoomAt(gesture.location(in: photo), scale: 2.5) }
        else if gesture.state == .ended || gesture.state == .cancelled { setZoomScale(1, animated: true) }
    }
    private func zoomAt(_ point: CGPoint, scale: CGFloat) {
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}

