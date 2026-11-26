// sckcap: capture the main display with ScreenCaptureKit, scaled on the GPU to WxH (letterboxed),
// and write raw NV12 frames to stdout as fast as they arrive (up to FPS).
// If the screen is idle, the last frame is repeated every 1/FPS so the encoder keeps a steady rate.
// Usage: sckcap [width] [height] [fps] [displayIndex]
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

let args = CommandLine.arguments
let W = args.count > 1 ? Int(args[1])! : 1920
let H = args.count > 2 ? Int(args[2])! : 1080
let FPS = args.count > 3 ? Int(args[3])! : 60
let screenArg = args.count > 4 ? args[4] : "0"

// Pick the display: "auto" -> the one matching WxH (the virtual "Goggles" display), else the first
// non-main display, else index 0. Otherwise a numeric index into SCShareableContent.displays.
func pickDisplay(_ displays: [SCDisplay]) -> SCDisplay {
    if screenArg == "auto" {
        if let d = displays.first(where: { $0.width == W && $0.height == H }) { return d }
        if let d = displays.first(where: { CGDisplayIsMain($0.displayID) == 0 }) { return d }
        return displays[0]
    }
    let i = Int(screenArg) ?? 0
    return i < displays.count ? displays[i] : displays[0]
}

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)
let out = FileHandle.standardOutput
let frameBytes = W * H * 3 / 2
var lastFrame = Data(count: frameBytes)
var lastWrite = DispatchTime.now()
let lock = NSLock()
var newFrames = 0, repeats = 0

func write(_ d: Data) {
    do { try out.write(contentsOf: d) } catch { exit(0) }  // reader gone
    lastWrite = DispatchTime.now()
}

final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // skip idle/blank status frames
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = att.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var d = Data(count: frameBytes)
        d.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var off = 0
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                let rows = plane == 0 ? H : H / 2
                for r in 0..<rows {
                    memcpy(dst.baseAddress! + off, base + r * bpr, W)
                    off += W
                }
            }
        }
        lock.lock(); lastFrame = d; newFrames += 1; stopsSinceFrame = 0; write(d); lock.unlock()
    }
    // SCK stops the stream on e.g. -3805 "application connection being interrupted" or when the captured display
    // goes away. Not fatal: the filler keeps repeating the last frame while the stream is rebuilt from fresh
    // SCShareableContent (the virtual display gets a new ID when re-created).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); if activeStream === stream { activeStream = nil }; stopsSinceFrame += 1; let n = stopsSinceFrame; lock.unlock()
        if n > MAXRESTARTS { err("sckcap: stream stopped: \(error) — \(n) stops without a frame in between, giving up"); exit(1) }
        err("sckcap: stream stopped: \(error) — restarting capture")
        restartStream()
    }
}

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let output = Output()
var activeStream: SCStream?
var capturedDisplayID: CGDirectDisplayID = 0  // display of the last successful start: re-attach to the same one on restart
var stopsSinceFrame = 0  // consecutive didStopWithError without a new frame arriving in between
let MAXRESTARTS = 8

func startStream() async throws -> SCDisplay {
    var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard !content.displays.isEmpty else { throw NSError(domain: "sckcap", code: 1, userInfo: [NSLocalizedDescriptionKey: "no displays"]) }
    // On restart prefer the display we had; in auto mode give a (re)created virtual display up to ~5 s to be listed.
    func pick() -> SCDisplay? {
        if capturedDisplayID != 0, let d = content.displays.first(where: { $0.displayID == capturedDisplayID }) { return d }
        if screenArg == "auto", !content.displays.contains(where: { $0.width == W && $0.height == H }) { return nil }
        return pickDisplay(content.displays)
    }
    var picked = pick()
    for _ in 0..<10 where picked == nil {
        try await Task.sleep(nanoseconds: 500_000_000)
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        picked = pick()
    }
    let display = picked ?? pickDisplay(content.displays)
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.width = W
    cfg.height = H
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(FPS))
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // copied out in the callback, the SCK buffer is never held
    cfg.showsCursor = true
    cfg.queueDepth = 3
    cfg.scalesToFit = true
    cfg.preservesAspectRatio = true
    cfg.backgroundColor = .black
    let s = SCStream(filter: filter, configuration: cfg, delegate: output)
    try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap", qos: .userInteractive))
    try await s.startCapture()
    lock.lock(); activeStream = s; capturedDisplayID = display.displayID; lock.unlock()
    return display
}

// Rebuild the stream after didStopWithError: backoff 0.5 s doubling to 4 s, up to MAXRESTARTS attempts per stop.
func restartStream() {
    Task {
        for attempt in 1...MAXRESTARTS {
            try? await Task.sleep(nanoseconds: UInt64(min(4.0, 0.5 * pow(2.0, Double(attempt - 1))) * 1e9))
            do {
                let d = try await startStream()
                err("sckcap: capture restarted (attempt \(attempt)): display \(d.displayID) \(d.width)x\(d.height)")
                return
            } catch { err("sckcap: restart attempt \(attempt) failed: \(error)") }
        }
        err("sckcap: could not restart capture after \(MAXRESTARTS) attempts"); exit(1)
    }
}

Task {
    do {
        let display = try await startStream()
        err("sckcap: capturing display \(display.displayID) \(display.width)x\(display.height) -> \(W)x\(H)@\(FPS)")
    } catch {
        err("sckcap: \(error)")
        exit(1)
    }
}

// idle filler: repeat the last frame when nothing new arrived for one frame interval
let interval = 1.0 / Double(FPS)
Thread {
    // precise filler loop (GCD timers coalesce and fired too rarely at 100 fps)
    while true {
        usleep(1000)
        lock.lock()
        let since = Double(DispatchTime.now().uptimeNanoseconds - lastWrite.uptimeNanoseconds) / 1e9
        if capturedDisplayID != 0 && since >= interval { repeats += 1; write(lastFrame) }  // also while a restart is pending
        lock.unlock()
    }
}.start()
if ProcessInfo.processInfo.environment["SCKCAP_STATS"] != nil {
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        lock.lock(); FileHandle.standardError.write("sckcap: new \(newFrames/2)/s repeat \(repeats/2)/s\n".data(using: .utf8)!)
        newFrames = 0; repeats = 0; lock.unlock()
    }
}
RunLoop.main.run()
