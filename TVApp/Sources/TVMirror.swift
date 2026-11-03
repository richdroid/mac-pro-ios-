#if os(iOS)
import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

// The TV's screen, live: the Mac streams it as H.264 (screenrecord's own Annex-B, 960 by 540), and the phone shows each
// picture as it comes, a fraction of a second behind the TV. When there's no stream to be had, the still pictures
// stand in, and the stream is tried again before long.
@MainActor
final class LiveMirror: ObservableObject {
    // A picture has come through, and the stream is still open.
    @Published private(set) var showing = false
    let layer = AVSampleBufferDisplayLayer()
    private var feed: LiveFeed?
    private var url: URL?
    private var wanted = false
    private var generation = 0
    private var failures = 0
    private var stopping: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
    }
    func start(_ url: URL?) {
        stopping?.cancel(); stopping = nil
        wanted = true
        if let url { self.url = url }
        guard feed == nil, retry == nil, let address = self.url else { return }
        generation += 1
        let gen = generation
        feed = LiveFeed(url: address, renderer: layer.sampleBufferRenderer,
                        picture: { [weak self] in Task { @MainActor in self?.pictured(gen) } },
                        ended: { [weak self] in Task { @MainActor in self?.ended(gen) } })
    }
    // Nobody looking: closed, after a moment's grace so a quick look elsewhere doesn't start it all over.
    func stop(after delay: TimeInterval = 0) {
        wanted = false
        stopping?.cancel()
        stopping = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, !self.wanted else { return }
            self.end()
        }
    }
    private func end() {
        feed?.cancel(); feed = nil
        retry?.cancel(); retry = nil
        generation += 1
        if showing { showing = false }
    }
    private func pictured(_ gen: Int) {
        guard gen == generation else { return }
        failures = 0
        if !showing { showing = true }
    }
    private func ended(_ gen: Int) {
        guard gen == generation else { return }
        feed = nil
        if showing { showing = false }
        failures += 1
        guard wanted else { return }
        // Again soon, backing off while the Mac has no stream to give, as an older one won't.
        let wait = min(30, 1.5 * Double(failures))
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            if self.wanted { self.start(nil) }
        }
    }
}

// One stream from the Mac, read as it arrives, cut at its start codes into NAL units, gathered into pictures, and
// handed to the display layer to show at once. Everything here runs on its own queue.
final class LiveFeed: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "tv.mirror.feed")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let renderer: AVSampleBufferVideoRenderer
    private let picture: @Sendable () -> Void
    private let ended: @Sendable () -> Void
    private var buffer = Data()
    private var sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    // The picture being gathered, and whether it starts a run (an IDR), which is where showing can begin.
    private var unit: [Data] = []
    private var unitKey = false
    private var sawKey = false
    // Most streams send each picture as one slice; one that doesn't has its slices gathered first.
    private var slices = false
    private var answered = false
    // The Mac marks the end of each picture with a delimiter: then nothing is ever guessed whole from a pause.
    private var delimited = false
    private var told = false
    private var finished = false
    private var quiet: DispatchWorkItem?

    init(url: URL, renderer: AVSampleBufferVideoRenderer, picture: @escaping @Sendable () -> Void, ended: @escaping @Sendable () -> Void) {
        self.renderer = renderer; self.picture = picture; self.ended = ended
        super.init()
        let ops = OperationQueue(); ops.maxConcurrentOperationCount = 1; ops.underlyingQueue = queue
        let config = URLSessionConfiguration.ephemeral
        // A still TV sends nothing for as long as it's still, so silence is never taken as the end.
        config.timeoutIntervalForRequest = 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: config, delegate: self, delegateQueue: ops)
        session = s
        var r = URLRequest(url: url)
        r.setValue("video/h264", forHTTPHeaderField: "Accept")
        task = s.dataTask(with: r)
        task?.resume()
        // An answer at all, soon, or it's not there to have.
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, !self.answered, !self.finished else { return }
            self.task?.cancel()
        }
    }
    func cancel() {
        queue.async { self.finished = true; self.quiet?.cancel() }
        task?.cancel()
        session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let ok = http?.statusCode == 200 && (type.contains("h264") || type.contains("octet-stream"))
        answered = ok
        completionHandler(ok ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        buffer.append(data)
        split(tail: false)
        // Nothing more for a moment: what's left is a whole unit, shown now rather than when the next one comes, which
        // for a still screen might be never. Long enough that a big picture still arriving isn't cut short.
        guard !delimited else { return }
        quiet?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.split(tail: true) }
        quiet = w
        queue.asyncAfter(deadline: .now() + 0.1, execute: w)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        quiet?.cancel()
        // Whatever came last is whole now: shown, so the last picture before the end isn't lost.
        if answered { split(tail: true) }
        finished = true
        session.finishTasksAndInvalidate()
        ended()
    }
    // Cuts the stream at each 00 00 01 (or 00 00 00 01). Every unit but the last is whole; the last is too once the
    // stream has gone quiet.
    private func split(tail: Bool) {
        guard !finished, !buffer.isEmpty else { return }
        var cuts: [(at: Int, length: Int)] = []
        buffer.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            while i + 3 <= n {
                if p[i] == 0 && p[i + 1] == 0 {
                    if p[i + 2] == 1 { cuts.append((i, 3)); i += 3; continue }
                    if i + 4 <= n && p[i + 2] == 0 && p[i + 3] == 1 { cuts.append((i, 4)); i += 4; continue }
                }
                i += 1
            }
        }
        guard let last = cuts.last else {
            // No start code in all this: not a stream to follow.
            if buffer.count > 2_000_000 { buffer.removeAll() }
            return
        }
        let base = buffer.startIndex
        for k in cuts.indices {
            let from = cuts[k].at + cuts[k].length
            let to = k + 1 < cuts.count ? cuts[k + 1].at : (tail ? buffer.count : -1)
            if to < 0 { break }
            if to > from { take(buffer.subdata(in: (base + from)..<(base + to))) }
        }
        if tail { buffer.removeAll(keepingCapacity: true); if slices { show() } }
        else { buffer.removeSubrange(base..<(base + last.at)) }
    }
    private func take(_ nal: Data) {
        var nal = nal
        // Zero bytes padding the end of a unit belong to no one.
        while nal.count > 1, nal.last == 0 { nal.removeLast() }
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7: if sps != nal { sps = nal; format = nil }
        case 8: if pps != nal { pps = nal; format = nil }
        // A delimiter between pictures.
        case 9: delimited = true; show()
        case 1, 5:
            // The first slice of a picture says so in its first bit (first_mb_in_slice is 0).
            let starts = nal.count > 1 && (nal[nal.startIndex + 1] & 0x80) != 0
            if !starts { slices = true }
            if starts { show() }
            unit.append(nal)
            if first & 0x1F == 5 { unitKey = true }
            if !slices { show() }
        default: break
        }
    }
    // The gathered picture, in the length-prefixed form the decoder takes, to be shown as soon as it's decoded.
    private func show() {
        defer { unit.removeAll(keepingCapacity: true); unitKey = false }
        guard !unit.isEmpty else { return }
        if format == nil, let sps, let pps { format = Self.format(sps, pps) }
        guard let format else { return }
        // After a hiccup the decoder starts again from the next whole picture.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush(); sawKey = false }
        if !sawKey { guard unitKey else { return }; sawKey = true }
        var block = Data()
        for n in unit {
            var length = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &length) { block.append(contentsOf: $0) }
            block.append(n)
        }
        guard let sample = Self.sample(block, format) else { return }
        renderer.enqueue(sample)
        if !told { told = true; picture() }
    }
    static func format(_ sps: Data, _ pps: Data) -> CMVideoFormatDescription? {
        var out: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> OSStatus in
            pps.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> OSStatus in
                guard let sp = s.bindMemory(to: UInt8.self).baseAddress, let pp = p.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [sp, pp]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                           parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
        }
        return status == noErr ? out : nil
    }
    static func sample(_ block: Data, _ format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var buffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: block.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: block.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &buffer) == kCMBlockBufferNoErr, let buffer else { return nil }
        let copied = block.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: block.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = block.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // No clock to keep: each picture is shown the moment it's decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// The live picture's layer, in a view SwiftUI can place. The one layer moves to whichever view shows it.
struct LiveMirrorLayer: UIViewRepresentable {
    let mirror: LiveMirror
    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.isUserInteractionEnabled = false
        v.attach(mirror.layer)
        return v
    }
    func updateUIView(_ v: Host, context: Context) { v.attach(mirror.layer) }
    final class Host: UIView {
        private weak var hosted: CALayer?
        func attach(_ l: CALayer) {
            if l.superlayer !== layer { l.removeFromSuperlayer(); layer.addSublayer(l) }
            hosted = l
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let hosted, hosted.superlayer === layer else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif
