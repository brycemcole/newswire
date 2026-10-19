#if DEBUG && targetEnvironment(simulator)
import QuartzCore
import UIKit

/// Counts main-thread frame hitches for the scroll benchmark in SessionUITests; active only when the test sets the path.
@MainActor final class FrameMeter: NSObject {
    private static var shared: FrameMeter?
    private let path: String
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var hitchMs = 0.0
    private var over25 = 0
    private var worstMs = 0.0
    private var started: CFTimeInterval = 0
    private var sweepStart: CFTimeInterval?
    private var finished = false
    private weak var scroller: UIScrollView?

    private init(path: String) { self.path = path }

    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NEWSWIRE_FRAME_STATS"], shared == nil else { return }
        let meter = FrameMeter(path: path)
        shared = meter
        let link = CADisplayLink(target: meter, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        meter.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        if started == 0 { started = link.timestamp }
        autoscroll(link.timestamp)
        guard last > 0 else { return }
        let interval = (link.timestamp - last) * 1000
        let expected = (link.targetTimestamp - link.timestamp) * 1000
        frames += 1
        if interval > expected * 1.5 {
            hitchMs += interval - expected
            if interval > 25 { over25 += 1 }
        }
        worstMs = max(worstMs, interval)
        if frames % 20 == 0 || finished { write() }
    }

    private func write() {
        let json = "{\"frames\":\(frames),\"hitchMs\":\(hitchMs),\"over25\":\(over25),\"worstMs\":\(worstMs),\"done\":\(finished ? 1 : 0)}"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// With NEWSWIRE_AUTOSCROLL set, sweeps the feed down and back after a warm-up, with no UI-test queries in the way.
    private func autoscroll(_ now: CFTimeInterval) {
        guard ProcessInfo.processInfo.environment["NEWSWIRE_AUTOSCROLL"] != nil, !finished, now - started > 8 else { return }
        if sweepStart == nil {
            guard let view = Self.largestScrollView() else { return }
            scroller = view
            sweepStart = now
            frames = 0; hitchMs = 0; over25 = 0; worstMs = 0; last = 0
        }
        guard let scroller, let begin = sweepStart else { return }
        let t = now - begin
        let duration = 24.0
        if t >= duration { finished = true; write(); return }
        let top = -scroller.adjustedContentInset.top
        let extent = min(scroller.contentSize.height - scroller.bounds.height, 9000)
        let phase = t / duration
        let position = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        scroller.contentOffset.y = top + extent * position
    }

    private static func largestScrollView() -> UIScrollView? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > (best?.contentSize.height ?? 1500) { best = scroll }
            view.subviews.forEach(visit)
        }
        visit(window)
        return best
    }
}
#endif
