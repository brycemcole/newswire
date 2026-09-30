import AVKit
import SwiftUI
import WebKit

/// A story's video in place of its photo: the poster until tapped, then an inline player. Nothing plays on its own.
struct StoryVideoView: View {
    let url: URL
    let poster: URL?
    let page: URL
    let title: String
    let source: String
    @State private var controller: AVPlayerViewController?
    @State private var embedding = false

    private var youtube: String? { ArticleExtractor.youtubeID(url) }

    var body: some View {
        Color.black
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let controller {
                    PlayerView(controller: controller)
                } else if embedding, let youtube {
                    YouTubeEmbed(id: youtube, referer: page)
                } else {
                    Button(action: play) {
                        Color.clear
                            .overlay { if let poster { ThumbnailImage(url: poster, size: ThumbnailLoader.large) } }
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 60, height: 60)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play video")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onAppear { controller = VideoPlayback.shared.controller(playing: url) }
            .onDisappear { VideoPlayback.shared.release(url) }
    }

    private func play() {
        if youtube != nil {
            embedding = true
            return
        }
        controller = VideoPlayback.shared.start(url, title: title, source: source, artwork: poster)
    }
}

/// Owns the one playing story video so it outlives the story screen: it keeps going in Picture in Picture when the
/// reader leaves the app (or the story while it is already floating), with its title and poster on the Lock Screen
/// and in the Dynamic Island through Now Playing.
final class VideoPlayback: NSObject, AVPlayerViewControllerDelegate {
    static let shared = VideoPlayback()

    private var controller: AVPlayerViewController?
    private var url: URL?
    private var floating = false
    private var onScreen = false

    func controller(playing url: URL) -> AVPlayerViewController? {
        guard self.url == url, let controller else { return nil }
        onScreen = true
        return controller
    }

    func start(_ url: URL, title: String, source: String, artwork: URL?) -> AVPlayerViewController {
        if let controller = controller(playing: url) { return controller }
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        let item = AVPlayerItem(url: url)
        item.externalMetadata = [Self.metadata(.commonIdentifierTitle, title), Self.metadata(.iTunesMetadataTrackSubTitle, source)]
        let player = AVPlayer(playerItem: item)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.delegate = self
        self.controller = controller
        self.url = url
        onScreen = true
        player.play()
        if let artwork {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: artwork), let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.8), self.url == url else { return }
                let art = AVMutableMetadataItem()
                art.identifier = .commonIdentifierArtwork
                art.value = jpeg as NSData
                art.dataType = kCMMetadataBaseDataType_JPEG as String
                art.extendedLanguageTag = "und"
                item.externalMetadata.append(art)
            }
        }
        return controller
    }

    /// The story screen went away. A floating video keeps playing; anything else stops.
    func release(_ url: URL) {
        guard self.url == url else { return }
        onScreen = false
        if !floating { stop() }
    }

    private func stop() {
        controller?.player?.pause()
        controller = nil
        url = nil
        floating = false
    }

    private static func metadata(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        floating = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        floating = false
        if !onScreen { stop() }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

private struct PlayerView: UIViewControllerRepresentable {
    let controller: AVPlayerViewController

    func makeUIViewController(context: Context) -> AVPlayerViewController { controller }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

private struct YouTubeEmbed: UIViewRepresentable {
    let id: String
    let referer: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        // YouTube refuses embeds without a referring page, so the player is hosted as if on the article's own site.
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube-nocookie.com/embed/\(id)?playsinline=1&autoplay=1&rel=0" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        view.loadHTMLString(html, baseURL: referer)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
