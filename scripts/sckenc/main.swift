// sckenc: capture a display with ScreenCaptureKit and encode it in hardware (VideoToolbox, low-latency
// rate control) to H.264. Always encodes the NEWEST frame: if the encoder is busy, older frames are dropped,
// never queued. When the screen is idle, the last frame is encoded again every 1/FPS so the goggles get a steady rate.
//
// Output on stdout, one record per access unit:
//   "SKE1" | u32 len | u64 capture_ns | u64 encoded_ns | u8 key | Annex-B AU (AUD, SPS/PPS on key frames, slices)
// Times are mach uptime ns (same clock as Python time.monotonic_ns() on macOS).
//
// Usage: sckenc [width] [height] [fps] [displayIndex] [kbit] [gopFrames] [appName]
// Env: SCKENC_STATS=1 prints per-3s stats to stderr, SCKENC_INFLIGHT=n frames in the encoder (default 2),
// SCKENC_LL=1 low-latency rate control, SCKENC_RT=1 RealTime (both slower on M1 Pro, see makeSession),
// SCKENC_NV12=1 capture NV12 instead of BGRA (breaks the virtual display, see PIXFMT).
// If ScreenCaptureKit stops the stream (e.g. -3805 "connection interrupted"), capture is restarted automatically.
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox

let a = CommandLine.arguments
func arg(_ i: Int, _ d: Int) -> Int { a.count > i ? Int(a[i]) ?? d : d }
let W = arg(1, 1920), H = arg(2, 1080), FPS = arg(3, 100)
let screenArg = a.count > 4 ? a[4] : "0"  // "auto" -> pick the virtual "Goggles" display (WxH / non-main)
let KBIT = arg(5, 40000), GOP = arg(6, 0)
let APP = a.count > 7 ? a[7].lowercased() : ""  // capture only this app's biggest window (name substring)

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

let lock = NSLock()
var latest: CVPixelBuffer?
var latestCapNs: UInt64 = 0
var latestIsNew = false
var inFlight = 0
let MAXFLIGHT = Int(ProcessInfo.processInfo.environment["SCKENC_INFLIGHT"] ?? "") ?? 2
var lastSubmit: UInt64 = 0
var nextDue: UInt64 = 0
let interval = UInt64(1e9 / Double(FPS))
var frameIndex: Int64 = 0
var capOf: [UInt64: UInt64] = [:]  // submit ns -> capture ns
var st = (new: 0, repeats: 0, skipped: 0, enc: 0, encUs: 0, bytes: 0, maxEncUs: 0, dropped: 0)
var bigChange = 0  // frames where >10% of the screen changed (= real game frames, not just the cursor)

// ---- encoder
var session: VTCompressionSession?
let outLock = NSLock()

var lastNew: UInt64 = 0
func stall(_ what: String, _ ms: Double) { if ms > 40 { log(String(format: "sckenc: STALL %@ %.0f ms", what, ms)) } }
func writeAll(_ d: Data) {
    let t0 = nowNs(); defer { stall("write to python (python/adb busy)", Double(nowNs() - t0) / 1e6) }
    d.withUnsafeBytes { p in
        var off = 0
        while off < d.count {
            let n = Darwin.write(1, p.baseAddress! + off, d.count - off)
            if n <= 0 { exit(0) }  // reader gone
            off += n
        }
    }
}

func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

// VT may return frames from different threads out of order when 2+ are in flight. The goggles decoder then sees
// "gaps in frame num". So records are written strictly in submit order.
var seqOf: [UInt64: Int64] = [:]  // submit ns -> sequence
var nextOut: Int64 = 1
var ready: [Int64: Data] = [:]  // empty Data = encoder dropped this frame

let outputCallback: VTCompressionOutputCallback = { _, srcRef, status, _, sb in
    let submitNs = UInt64(UInt(bitPattern: srcRef))
    let rec = makeRecord(submitNs, status, sb)
    outLock.lock()
    lock.lock(); let seq = seqOf.removeValue(forKey: submitNs) ?? nextOut; lock.unlock()
    ready[seq] = rec ?? Data()
    while let r = ready.removeValue(forKey: nextOut) {
        if !r.isEmpty { writeAll(fixRecord(r)) }
        nextOut += 1
    }
    outLock.unlock()
    lock.lock(); inFlight -= 1; lock.unlock(); kick()
}

func makeRecord(_ submitNs: UInt64, _ status: OSStatus, _ sb: CMSampleBuffer?) -> Data? {
    guard status == noErr, let sb = sb, let block = CMSampleBufferGetDataBuffer(sb) else {
        lock.lock(); st.dropped += 1; _ = capOf.removeValue(forKey: submitNs); lock.unlock(); return nil
    }
    var key = true
    if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
       let ns = att.first?[kCMSampleAttachmentKey_NotSync] as? Bool, ns { key = false }
    let sc = Data([0, 0, 0, 1])
    var au = Data([0, 0, 0, 1, 0x09, 0xF0])  // AUD
    if key, let fd = CMSampleBufferGetFormatDescription(sb) {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?; var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let ptr = ptr { au += sc; au += Data(bytes: ptr, count: size) }
        }
    }
    var len = 0; var dp: UnsafeMutablePointer<Int8>?
    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &dp)
    guard let base = dp else { return nil }
    let raw = UnsafeRawPointer(base)
    var off = 0
    while off + 4 <= len {
        let n = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
        off += 4
        if n <= 0 || off + n > len { break }
        au += sc; au += Data(bytes: raw + off, count: n)
        off += n
    }
    lock.lock(); let capNs = capOf.removeValue(forKey: submitNs) ?? submitNs; lock.unlock()
    let encNs = nowNs()
    var rec = Data("SKE1".utf8)
    rec += le(UInt32(au.count)); rec += le(capNs); rec += le(encNs); rec += Data([key ? 1 : 0])
    rec += au
    lock.lock()
    let us = Int((encNs - submitNs) / 1000)
    stall("encoder", Double(us) / 1000)
    st.enc += 1; st.encUs += us; st.maxEncUs = max(st.maxEncUs, us); st.bytes += au.count
    lock.unlock()
    return rec
}


// ---- frame_num fix for the goggles decoder
// VideoToolbox writes frame_num with 5 bits (0..31). The goggles' Hantro decoder seems to wrap it at 16: it logs
// "Gaps in frame num" for frames 16..31 of every 32 and shows them badly (felt like 15-50 fps in games).
// We rewrite the SPS to 4-bit frame_num and move the spare bit to pic_order_cnt_lsb, and rewrite every slice
// header to match. Header length stays the same, so the slice data is untouched.
let FIX = ProcessInfo.processInfo.environment["SCKENC_NOFIX"] == nil
var fnBits = 0, pocBits = 0, newPocBits = 0, frameSinceIdr = 0, fixOn = false

func unescape(_ b: ArraySlice<UInt8>) -> [UInt8] {
    var o: [UInt8] = []; o.reserveCapacity(b.count); var z = 0
    for x in b { if z >= 2 && x == 3 { z = 0; continue }; o.append(x); z = x == 0 ? z + 1 : 0 }
    return o
}
func escape(_ b: [UInt8]) -> [UInt8] {
    var o: [UInt8] = []; o.reserveCapacity(b.count + 4); var z = 0
    for x in b { if z >= 2 && x <= 3 { o.append(3); z = 0 }; o.append(x); z = x == 0 ? z + 1 : 0 }
    return o
}
struct Bits {
    var b: [UInt8] = []  // one bit per element
    var p = 0
    init(_ bytes: [UInt8]) { for x in bytes { for i in (0..<8).reversed() { b.append((x >> UInt8(i)) & 1) } } }
    mutating func u(_ n: Int) -> Int { var v = 0; for _ in 0..<n { v = v << 1 | Int(b[p]); p += 1 }; return v }
    mutating func ue() -> Int { var z = 0; while b[p] == 0 { z += 1; p += 1 }; p += 1; return (1 << z) - 1 + u(z) }
}
func putU(_ o: inout [UInt8], _ v: Int, _ n: Int) { for i in (0..<n).reversed() { o.append(UInt8((v >> i) & 1)) } }
func putUE(_ o: inout [UInt8], _ v: Int) { let x = v + 1; let n = Int.bitWidth - x.leadingZeroBitCount; putU(&o, 0, n - 1); putU(&o, x, n) }
func pack(_ bits: [UInt8]) -> [UInt8] {
    var o = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
    for (i, x) in bits.enumerated() where x != 0 { o[i / 8] |= 0x80 >> UInt8(i % 8) }
    return o
}

func fixSPS(_ nal: [UInt8]) -> [UInt8] {  // nal = escaped NAL incl. header byte
    var r = Bits(unescape(nal[1...]))
    let prof = r.u(8); _ = r.u(16); _ = r.ue()
    if [100, 110, 122, 244, 44, 83, 86, 118, 128].contains(prof) {
        let cf = r.ue(); if cf == 3 { _ = r.u(1) }; _ = r.ue(); _ = r.ue(); _ = r.u(1)
        if r.u(1) == 1 { fixOn = false; return nal }  // scaling matrices: not handled
    }
    let start = r.p
    fnBits = r.ue() + 4
    let pocType = r.ue()
    guard pocType == 0 else { fixOn = false; return nal }
    pocBits = r.ue() + 4
    let rest = r.p
    guard fnBits > 4 else { fixOn = false; return nal }
    newPocBits = min(16, pocBits + fnBits - 4)
    var o = Array(r.b[0..<start])
    putUE(&o, 0); putUE(&o, 0); putUE(&o, newPocBits - 4)
    var tail = Array(r.b[rest...])
    while let l = tail.last, l == 0 { tail.removeLast() }  // drop rbsp trailing bits, re-add below
    tail.removeLast()
    o += tail; o.append(1); while o.count % 8 != 0 { o.append(0) }
    fixOn = true
    return [nal[0]] + escape(pack(o))
}

func fixSlice(_ nal: [UInt8]) -> [UInt8] {
    let idr = nal[0] & 31 == 5
    if idr { frameSinceIdr = 0 }
    defer { frameSinceIdr += 1 }
    // split: a prefix that holds the header, cut after a non-zero byte so escaping of the rest is unchanged
    var cut = min(nal.count, 24)
    while cut < nal.count && (nal[cut - 1] == 0 || nal[cut - 1] == 3) { cut += 1 }
    var r = Bits(unescape(nal[1..<cut]))
    _ = r.ue(); _ = r.ue(); _ = r.ue()
    let fnAt = r.p; _ = r.u(fnBits)
    if idr { _ = r.ue() }
    let pocAt = r.p; _ = r.u(pocBits)
    let after = r.p
    var o = Array(r.b[0..<fnAt])
    putU(&o, frameSinceIdr % 16, 4)
    o += r.b[(fnAt + fnBits)..<pocAt]
    putU(&o, frameSinceIdr % (1 << newPocBits), newPocBits)
    o += r.b[after...]
    guard o.count == r.b.count else { return nal }
    return [nal[0]] + escape(pack(o)) + Array(nal[cut...])
}

// records arrive here in stream order (frame counter must follow output order)
func fixRecord(_ r: Data) -> Data {
    guard FIX else { return r }
    let au = fixAU(r.subdata(in: (r.startIndex + 25)..<r.endIndex))
    var o = Data(r[r.startIndex..<(r.startIndex + 4)]); o += le(UInt32(au.count))
    o += r[(r.startIndex + 8)..<(r.startIndex + 25)]; o += au
    return o
}

func fixAU(_ au: Data) -> Data {
    let b = [UInt8](au)
    var starts: [Int] = []  // positions after 00 00 00 01
    var i = 0
    while i + 4 <= b.count { if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1 { starts.append(i + 4); i += 4 } else { i += 1 } }
    var out = Data()
    for (k, s) in starts.enumerated() {
        let e = k + 1 < starts.count ? starts[k + 1] - 4 : b.count
        var nal = Array(b[s..<e])
        let t = nal[0] & 31
        if t == 7 { nal = fixSPS(nal) } else if fixOn && (t == 1 || t == 5) { nal = fixSlice(nal) }
        out += [0, 0, 0, 1]; out += nal
    }
    return out
}

func makeSession() {
    let spec: [CFString: Any] = [
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: ProcessInfo.processInfo.environment["SCKENC_LL"] != nil,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ]
    var s: VTCompressionSession?
    let err = VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_H264,
        encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: outputCallback, refcon: nil, compressionSessionOut: &s)
    guard err == noErr, let s = s else { log("sckenc: VTCompressionSessionCreate failed \(err)"); exit(1) }
    func set(_ k: CFString, _ v: Any) {
        let e = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
        if e != noErr { log("sckenc: property \(k) failed \(e)") }
    }
    // RealTime=true and low-latency RC both cap the M1 Pro encoder at ~70 fps (1080p). Without them: ~146 fps.
    if ProcessInfo.processInfo.environment["SCKENC_RT"] != nil { set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!) }
    set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
    set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse!)
    set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue!)
    set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
    // The goggles decoder (VC8000D) waits for max_dec_frame_buffering frames before output. In low-latency mode VT uses
    // 15 refs and the decoder stalls. One reference frame = output right away.
    if ProcessInfo.processInfo.environment["SCKENC_LL"] != nil { set(kVTCompressionPropertyKey_ReferenceBufferCount, 1) }  // normal mode already uses 1
    set(kVTCompressionPropertyKey_AverageBitRate, KBIT * 1000)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, FPS)
    set(kVTCompressionPropertyKey_MaxKeyFrameInterval, GOP > 0 ? GOP : FPS * 2)
    set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Double(GOP > 0 ? GOP : FPS * 2) / Double(FPS))
    VTCompressionSessionPrepareToEncodeFrames(s)
    session = s
}

// Encode the newest frame if the encoder is free. Called on new capture and from the idle filler.
func kick(repeatOnly: Bool = false) {
    lock.lock()
    guard let s = session, let pb = latest, inFlight < MAXFLIGHT else {  // busy: picked up when an encode finishes
        lock.unlock(); return
    }
    // Steady cadence of exactly FPS frames/s (the goggles panel is 100 Hz; more than that only causes judder).
    // A new frame goes out at once if its slot is (almost) due, otherwise at its slot. No new frame at the
    // slot = repeat the last one.
    let t = nowNs()
    let slack: UInt64 = repeatOnly ? 0 : 2_000_000
    if t + slack < nextDue { lock.unlock(); return }
    let isRepeat = !latestIsNew
    if isRepeat { st.repeats += 1 }
    nextDue = max(nextDue, t &- interval / 2) + interval
    latestIsNew = false
    inFlight += 1
    lastSubmit = t
    frameIndex += 1
    seqOf[t] = frameIndex
    capOf[t] = isRepeat ? t : latestCapNs  // a repeat counts as captured now
    let pts = CMTime(value: CMTimeValue(t), timescale: 1_000_000_000)  // must increase: repeats get a fresh pts
    lock.unlock()
    let err = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
        frameProperties: nil, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(t)), infoFlagsOut: nil)
    if err != noErr {  // no callback will come for this frame: mark it as dropped
        log("sckenc: encode error \(err)")
        outLock.lock(); lock.lock(); let seq = seqOf.removeValue(forKey: t) ?? 0; inFlight -= 1; lock.unlock()
        ready[seq] = Data(); while let r = ready.removeValue(forKey: nextOut) { if !r.isEmpty { writeAll(fixRecord(r)) }; nextOut += 1 }
        outLock.unlock()
    }
}

final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = att.first?[.status] as? Int, let s = SCFrameStatus(rawValue: raw), s != .complete { return }
        var area = 0.0
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let rects = att.first?[.dirtyRects] as? [NSDictionary] {
            for d in rects { if let r = CGRect(dictionaryRepresentation: d) { area += Double(r.width * r.height) } }
            if let sr = att.first?[.contentRect] as? NSDictionary, let c = CGRect(dictionaryRepresentation: sr),
               let sf = att.first?[.scaleFactor] as? Double { area /= Double(c.width * c.height) * sf * sf }
        }
        lock.lock()
        if area > 0.1 { bigChange += 1 }
        if latestIsNew { st.skipped += 1 }  // previous new frame never got encoded: dropped, not queued
        latest = pb
        latestCapNs = UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1e9)
        latestIsNew = true
        st.new += 1
        let tn = nowNs(); if lastNew > 0 { stall("no new frame from macOS capture", Double(tn - lastNew) / 1e6) }; lastNew = tn
        stopsSinceFrame = 0
        lock.unlock()
        kick()
    }
    // SCK stops the stream on e.g. -3805 "application connection being interrupted" (seen ~1 min into capturing the
    // virtual display) or when the captured display goes away. Not fatal: the idle filler keeps repeating the last
    // frame, and we rebuild the stream from fresh SCShareableContent (the virtual display gets a new ID when re-created).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); if activeStream === stream { activeStream = nil }; stopsSinceFrame += 1; let n = stopsSinceFrame; lock.unlock()
        if n > MAXRESTARTS { log("sckenc: stream stopped: \(error) — \(n) stops without a single frame in between, giving up"); exit(1) }
        log("sckenc: stream stopped: \(error) — restarting capture")
        restartStream()
    }
}

let output = Output()
var activeStream: SCStream?
var capturedDisplayID: CGDirectDisplayID = 0  // display of the last successful start: re-attach to the same one on restart
var stopsSinceFrame = 0  // consecutive didStopWithError without a new frame arriving in between
let MAXRESTARTS = 8
// SCK hands out two IOSurfaces in rotation. When the stream delivers NV12 1:1 from the virtual display and VideoToolbox
// encodes that surface directly, SCK delivers exactly ONE frame and then nothing more (bisected 2026-11-25 on macOS 27.2.1:
// no encoder -> 83 fps, BGRA -> 73-95 fps, NV12 -> 1 frame; the real display is unaffected). Assumption: the hardware
// encoder keeps the NV12 input surface in use as its reference picture and SCK waits for it. BGRA input costs the
// encoder ~0.4 ms more per frame (5.3 vs 4.9 ms) and the conversion happens on the GPU. SCKENC_NV12=1 restores the old format.
let PIXFMT = ProcessInfo.processInfo.environment["SCKENC_NV12"] != nil ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
makeSession()

// Pick the display. "auto": the display we captured before (same ID), else the one matching WxH (the virtual "Goggles"
// display), else the first non-main, else index 0. Numeric: that index into SCShareableContent.displays.
func pickDisplay(_ displays: [SCDisplay]) -> SCDisplay? {
    if capturedDisplayID != 0, let d = displays.first(where: { $0.displayID == capturedDisplayID }) { return d }
    if screenArg == "auto" {
        if let d = displays.first(where: { $0.width == W && $0.height == H }) { return d }
        return nil  // caller retries: SCShareableContent sometimes omits the virtual display for a moment
    }
    let i = Int(screenArg) ?? 0
    return i < displays.count ? displays[i] : displays[0]
}

func startStream() async throws -> String {
    var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard !content.displays.isEmpty else { throw NSError(domain: "sckenc", code: 1, userInfo: [NSLocalizedDescriptionKey: "no displays"]) }
    var picked = pickDisplay(content.displays)
    for _ in 0..<10 where picked == nil {  // auto: give a (re)created virtual display up to ~5 s to show up
        try await Task.sleep(nanoseconds: 500_000_000)
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        picked = pickDisplay(content.displays)
    }
    let display: SCDisplay
    if let p = picked { display = p } else {
        display = content.displays.first(where: { CGDisplayIsMain($0.displayID) == 0 }) ?? content.displays[0]
        log("sckenc: no \(W)x\(H) display found, falling back to display \(display.displayID) \(display.width)x\(display.height)")
    }
    let cfg = SCStreamConfiguration()
    cfg.width = W
    cfg.height = H
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(FPS))
    cfg.pixelFormat = PIXFMT
    cfg.showsCursor = true
    cfg.queueDepth = 5
    cfg.scalesToFit = true
    cfg.preservesAspectRatio = true
    cfg.backgroundColor = .black
    var filter = SCContentFilter(display: display, excludingWindows: [])
    var what = "display \(display.displayID) \(display.width)x\(display.height)"
    if !APP.isEmpty {
        // A fullscreen game lives in its own Space, so it is not "on screen" while Terminal is in front:
        // search all windows, by app name, bundle id or window title.
        func match(_ w: SCWindow) -> Bool {
            let keys = [w.owningApplication?.applicationName, w.owningApplication?.bundleIdentifier, w.title]
            return w.frame.width > 300 && w.frame.height > 200 && keys.contains { ($0 ?? "").lowercased().contains(APP) }
        }
        var found: SCWindow?
        for i in 0..<30 {  // the game may still be starting
            let all = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            found = all.windows.filter(match).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            if found != nil { break }
            if i == 0 {
                let apps = Set(all.windows.filter { $0.frame.width > 300 }.compactMap { $0.owningApplication?.applicationName }).sorted()
                log("sckenc: no window for '\(APP)' yet, waiting. Apps with windows: \(apps.joined(separator: ", "))")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // Throw (don't exit) so the restart path can retry: the window may be briefly absent during a rebuild.
        guard let w = found else { throw NSError(domain: "sckenc", code: 2, userInfo: [NSLocalizedDescriptionKey: "no window for '\(APP)'"]) }
        filter = SCContentFilter(desktopIndependentWindow: w)
        what = "window '\(w.title ?? "")' of \(w.owningApplication?.applicationName ?? "") \(Int(w.frame.width))x\(Int(w.frame.height))"
    }
    let s = SCStream(filter: filter, configuration: cfg, delegate: output)
    try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap", qos: .userInteractive))
    try await s.startCapture()
    lock.lock(); activeStream = s; capturedDisplayID = display.displayID; lock.unlock()
    return what
}

// Rebuild the stream after didStopWithError: backoff 0.5 s doubling to 4 s, up to MAXRESTARTS attempts per stop.
func restartStream() {
    Task {
        for attempt in 1...MAXRESTARTS {
            try? await Task.sleep(nanoseconds: UInt64(min(4.0, 0.5 * pow(2.0, Double(attempt - 1))) * 1e9))
            do {
                let what = try await startStream()
                log("sckenc: capture restarted (attempt \(attempt)): \(what)")
                return
            } catch { log("sckenc: restart attempt \(attempt) failed: \(error)") }
        }
        log("sckenc: could not restart capture after \(MAXRESTARTS) attempts"); exit(1)
    }
}

Task {
    do {
        let what = try await startStream()
        log("sckenc: \(what) -> \(W)x\(H)@\(FPS), \(KBIT) kbit, VideoToolbox, \(PIXFMT == kCVPixelFormatType_32BGRA ? "BGRA" : "NV12") capture")
    } catch { log("sckenc: \(error)"); exit(1) }
}

Thread {
    while true { usleep(1000); kick(repeatOnly: true) }
}.start()

if ProcessInfo.processInfo.environment["SCKENC_STATS"] != nil {
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
        lock.lock()
        let e = max(st.enc, 1)
        log("sckenc: screen changes \(bigChange / 3)/s | capture \(st.new / 3)/s repeat \(st.repeats / 3)/s skipped \(st.skipped / 3)/s | encoded \(st.enc / 3)/s "
            + "enc \(st.encUs / e / 1000).\(st.encUs / e / 100 % 10) ms avg \(st.maxEncUs / 1000) max | \(st.bytes * 8 / 3 / 1000) kbit/s | vt dropped \(st.dropped)")
        st = (0, 0, 0, 0, 0, 0, 0, 0); bigChange = 0
        lock.unlock()
    }
}
RunLoop.main.run()
