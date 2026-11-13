import Foundation
import AVFoundation
import AVKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(KSPlayer)
import KSPlayer
#endif

// What plays a stream on this phone. KSPlayer when the build has it (its FFmpeg player takes the MKV and HEVC files his
// add-ons mostly give; AVPlayer takes the rest), else AVPlayer alone. Either way: Picture in Picture from a sample-buffer
// layer or the player layer, AirPlay through the system's route picker, and tracks named for the menus.

struct PhoneTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let selected: Bool
}

#if os(iOS)
@MainActor protocol PhoneEngine: AnyObject {
    var view: UIView { get }
    var position: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var error: String? { get }
    var ended: Bool { get }
    var rate: Float { get set }
    var fill: Bool { get set }
    var pip: AVPictureInPictureController? { get }
    var onPiP: (@MainActor (Bool) -> Void)? { get set }
    func play()
    func pause()
    func seek(to seconds: Double)
    func tracks(audio: Bool) -> [PhoneTrack]
    func select(_ id: String?, audio: Bool)
    func subtitle(at seconds: Double) -> String?
    func shutdown()
}

@MainActor enum PhoneEngines {
    static func make(url: URL, headers: [String: String], start: Double) -> PhoneEngine {
        #if canImport(KSPlayer)
        return KSEngine(url: url, headers: headers, start: start)
        #else
        return AVEngine(url: url, headers: headers, start: start)
        #endif
    }
    static var name: String {
        #if canImport(KSPlayer)
        return "KSPlayer"
        #else
        return "AVPlayer"
        #endif
    }
}

// What a track is called in the menu: its language in words, then what the file names it, without saying either twice.
func trackName(language: String?, name: String, index: Int) -> String {
    let lang = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? ""
    let n = name.trimmingCharacters(in: .whitespaces)
    if lang.isEmpty { return n.isEmpty ? "Track \(index + 1)" : n }
    if n.isEmpty || n.lowercased() == lang.lowercased() || n.lowercased() == language?.lowercased() { return lang }
    return n.lowercased().contains(lang.lowercased()) ? n : "\(lang) · \(n)"
}

final class PlayerHostView: UIView {
    override func layoutSubviews() { super.layoutSubviews(); subviews.forEach { $0.frame = bounds } }
}

// MARK: AVPlayer

final class AVLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

@MainActor final class AVEngine: NSObject, PhoneEngine, AVPictureInPictureControllerDelegate {
    let player: AVPlayer
    private let shown = AVLayerView()
    var view: UIView { shown }
    private(set) var error: String?
    private(set) var ended = false
    private var groups: [Bool: AVMediaSelectionGroup] = [:]
    private var watchers: [NSKeyValueObservation] = []
    let pip: AVPictureInPictureController?
    var onPiP: (@MainActor (Bool) -> Void)?
    init(url: URL, headers: [String: String], start: Double) {
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        shown.playerLayer.player = player
        shown.playerLayer.videoGravity = .resizeAspect
        shown.backgroundColor = .black
        pip = AVPictureInPictureController.isPictureInPictureSupported() ? AVPictureInPictureController(playerLayer: shown.playerLayer) : nil
        super.init()
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
        pip?.delegate = self
        watchers.append(item.observe(\.status) { [weak self] i, _ in
            Task { @MainActor in
                guard let self else { return }
                if i.status == .failed { self.error = i.error?.localizedDescription ?? "This stream won’t play on the phone." }
                if i.status == .readyToPlay { await self.loadGroups(asset) }
            }
        })
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended = true }
        }
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        player.play()
    }
    private func loadGroups(_ asset: AVURLAsset) async {
        groups[true] = try? await asset.loadMediaSelectionGroup(for: .audible)
        groups[false] = try? await asset.loadMediaSelectionGroup(for: .legible)
    }
    var position: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: Double { let d = player.currentItem?.duration.seconds ?? 0; return d.isFinite ? d : 0 }
    var isPlaying: Bool { player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    var isBuffering: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate || player.currentItem?.status == .unknown }
    var rate: Float {
        get { player.defaultRate }
        set { player.defaultRate = newValue; if player.rate > 0 { player.rate = newValue } }
    }
    var fill: Bool {
        get { shown.playerLayer.videoGravity == .resizeAspectFill }
        set { shown.playerLayer.videoGravity = newValue ? .resizeAspectFill : .resizeAspect }
    }
    func play() { ended = false; player.play() }
    func pause() { player.pause() }
    func seek(to seconds: Double) { ended = false; player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) }
    func tracks(audio: Bool) -> [PhoneTrack] {
        guard let g = groups[audio], let item = player.currentItem else { return [] }
        let on = item.currentMediaSelection.selectedMediaOption(in: g)
        return g.options.enumerated().map { i, o in
            PhoneTrack(id: "\(i)", name: trackName(language: o.extendedLanguageTag ?? o.locale?.language.languageCode?.identifier, name: o.displayName, index: i), selected: o == on)
        }
    }
    func select(_ id: String?, audio: Bool) {
        guard let g = groups[audio], let item = player.currentItem else { return }
        let o = id.flatMap(Int.init).flatMap { $0 < g.options.count ? g.options[$0] : nil }
        item.select(o, in: g)
    }
    // AVPlayer draws its own subtitles.
    func subtitle(at seconds: Double) -> String? { nil }
    func shutdown() { player.pause(); player.replaceCurrentItem(with: nil); watchers = [] }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.onPiP?(true) } }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.onPiP?(false) } }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        done(true)
    }
}

// MARK: KSPlayer

#if canImport(KSPlayer)
@MainActor final class KSEngine: NSObject, PhoneEngine, KSPlayerLayerDelegate, AVPictureInPictureControllerDelegate {
    let layer: KSPlayerLayer
    private let host = PlayerHostView()
    var view: UIView { host }
    private(set) var state: KSPlayerState = .initialized
    private(set) var error: String?
    private(set) var ended = false
    private var subtitleTrack: (any MediaPlayerTrack)?
    var onPiP: (@MainActor (Bool) -> Void)?
    init(url: URL, headers: [String: String], start: Double) {
        KSOptions.canBackgroundPlay = true
        KSOptions.isPipPopViewController = false
        // A file AVPlayer can open goes to it first (it hands its picture to AirPlay whole); anything else to FFmpeg. Each
        // falls back to the other when it can't.
        let native = ["m3u8", "mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
        if native { KSOptions.firstPlayerType = KSAVPlayer.self; KSOptions.secondPlayerType = KSMEPlayer.self }
        else { KSOptions.firstPlayerType = KSMEPlayer.self; KSOptions.secondPlayerType = KSAVPlayer.self }
        let o = KSOptions()
        o.registerRemoteControll = false
        o.canStartPictureInPictureAutomaticallyFromInline = true
        o.userAgent = "Mozilla/5.0"
        if !headers.isEmpty {
            o.avOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
            o.formatContextOptions["headers"] = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        }
        layer = KSPlayerLayer(url: url, isAutoPlay: true, options: o, delegate: nil)
        host.backgroundColor = .black
        super.init()
        layer.delegate = self
        if start > 0 { layer.seek(time: start, autoPlay: true) { _ in } }
        attach()
    }
    private func attach() {
        guard let v = layer.player.view, v.superview == nil else { return }
        v.frame = host.bounds
        host.addSubview(v)
    }
    var position: Double { let t = layer.player.currentPlaybackTime; return t.isFinite ? t : 0 }
    var duration: Double { let d = layer.player.duration; return d.isFinite ? d : 0 }
    var isPlaying: Bool { state == .bufferFinished || state == .buffering || (state == .readyToPlay && layer.player.isPlaying) }
    var isBuffering: Bool { [.initialized, .preparing, .buffering].contains(state) }
    var rate: Float {
        get { layer.player.playbackRate }
        set { layer.player.playbackRate = newValue }
    }
    var fill: Bool {
        get { layer.player.contentMode == .scaleAspectFill }
        set { layer.player.contentMode = newValue ? .scaleAspectFill : .scaleAspectFit }
    }
    // Asked only once the player is ready: FFmpeg's player makes its controller the first time it's asked.
    var pip: AVPictureInPictureController? { [.initialized, .preparing].contains(state) ? nil : layer.player.pipController }
    func play() { ended = false; layer.play() }
    func pause() { layer.pause() }
    func seek(to seconds: Double) {
        ended = false
        layer.seek(time: max(0, seconds), autoPlay: state != .paused) { _ in }
    }
    func tracks(audio: Bool) -> [PhoneTrack] {
        let all = layer.player.tracks(mediaType: audio ? .audio : .subtitle)
        return all.enumerated().map { i, t in
            PhoneTrack(id: "\(t.trackID)", name: trackName(language: t.languageCode, name: t.name, index: i),
                       selected: audio ? t.isEnabled : (subtitleTrack.map { $0 === t } ?? false))
        }
    }
    func select(_ id: String?, audio: Bool) {
        let all = layer.player.tracks(mediaType: audio ? .audio : .subtitle)
        guard let id, let t = all.first(where: { "\($0.trackID)" == id }) else {
            if !audio { if let was = subtitleTrack, was.isImageSubtitle { was.isEnabled = false }; subtitleTrack = nil }
            return
        }
        layer.player.select(track: t)
        if !audio { subtitleTrack = t }
    }
    // FFmpeg's subtitles are drawn by the app: the chosen track's lines at this moment.
    func subtitle(at seconds: Double) -> String? {
        guard let t = subtitleTrack as? any KSSubtitleProtocol else { return nil }
        let lines = t.search(for: seconds).compactMap { $0.text?.string }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    func shutdown() { layer.delegate = nil; layer.stop() }

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        self.state = state
        PhoneLog.note("ks \(state) \(type(of: layer.player))")
        if state == .readyToPlay {
            attach()
            pip?.delegate = self
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        if state == .error, error == nil { error = "This stream won’t play on the phone." }
    }
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {}
    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error { self.error = error.localizedDescription.isEmpty ? "This stream won’t play on the phone." : error.localizedDescription }
        else { ended = true }
    }
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.onPiP?(true) } }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { Task { @MainActor in self.onPiP?(false) } }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        done(true)
    }
}
#endif
#endif
