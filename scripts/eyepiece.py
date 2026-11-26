#!/usr/bin/env python3
"""Eyepiece client for macOS: Mac screen -> DJI Goggles 3 over USB.

Capture: bin/sckcap (ScreenCaptureKit, scaled to 1920x1080 on the GPU).
Encode: ffmpeg libx264 ultrafast/zerolatency, one slice per frame.
Send: natartos Eyepiece protocol over `adb forward tcp:42420` to eyepiece_bridge,
which decodes in hardware (VC8000D) and shows frames on the VIDEO0 plane.

Usage: eyepiece.py [--fps 100] [--mbit 20] [--start-bridge] [--bridge-opts=-b]
  --start-bridge  run eyepiece_bridge over adb (otherwise open More -> Eyepiece on the goggles)
  --headtrack     ask the goggles for head pose (not tested much)
Debug: --source testsrc (ffmpeg test pattern), --avf (old avfoundation capture), --vt (VideoToolbox).
"""
import argparse, select, socket, struct, subprocess, sys, threading, time

def _serial():
    import os
    if os.environ.get("EYEPIECE_SERIAL"):
        return os.environ["EYEPIECE_SERIAL"]
    out = subprocess.run(["adb", "devices", "-l"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "e3t_zv902" in line:
            return line.split()[0]
    sys.exit("DJI Goggles 3 not found in adb mode (run goggles.command)")


SERIAL = _serial()
PORT = 42420
BRIDGE = "/vendor/natartos/apps/eyepiece/eyepiece_bridge"
W, H = 1920, 1080

ap = argparse.ArgumentParser()
ap.add_argument("--fps", type=int, default=100)
ap.add_argument("--mbit", type=float, default=0, help="bitrate, default 40 (hardware) or 20 (--x264)")
ap.add_argument("--secs", type=float, default=0)
ap.add_argument("--screen", default="0", help="display index, or 'auto' to pick the virtual Goggles display (matches WxH, else first non-main)")
ap.add_argument("--record", default="", help="debug: also save the sent H.264 to this file (+ .csv with times)")
ap.add_argument("--app", default="", help="capture only this app's window (name substring), e.g. --app minecraft")
ap.add_argument("--start-bridge", action="store_true")
ap.add_argument("--headtrack", action="store_true")
ap.add_argument("--avf", action="store_true", help="capture with ffmpeg avfoundation (only ~20 fps); default is sckcap (ScreenCaptureKit)")
ap.add_argument("--source", default="", help="lavfi test source instead of the screen, e.g. testsrc")
ap.add_argument("--gop", type=int, default=0)
ap.add_argument("--vt", action="store_true", help="ffmpeg h264_videotoolbox (adds ~110 ms, debug only)")
ap.add_argument("--x264", action="store_true", help="old path: sckcap -> ffmpeg libx264 (CPU). Default is bin/sckenc (hardware, newest frame only)")
ap.add_argument("--disp-ts", default="", help="EYEPIECE_DISP_TS for --start-bridge: keep|zero|now")
ap.add_argument("--bridge-opts", default="", help="extra eyepiece_bridge options, e.g. '-O fb'")
ap.add_argument("--preset", default="veryfast", help="x264 preset (default veryfast; was ultrafast). "
                "veryfast = sharper at the same bitrate, ~2.4 ms/frame encode (still fine for low latency).")
args = ap.parse_args()


def adb(*a, **kw):
    return subprocess.run(["adb", "-s", SERIAL, *a], **kw)


def msg(t, payload, flags=0):
    return struct.pack("<BBBBI", ord("E"), ord("P"), t, flags, len(payload)) + payload


bridge = None
if args.start_bridge:
    adb("shell", f"pkill -f {BRIDGE}; true")
    opts = ("" if args.headtrack else "-H") + " " + args.bridge_opts
    bridge = subprocess.Popen(["adb", "-s", SERIAL, "shell", (f"EYEPIECE_DISP_TS={args.disp_ts} " if args.disp_ts else "") + f"EYEPIECE_METRICS=1 {BRIDGE} {opts} -M -l /data/local/tmp/eyepiece.log"])
    time.sleep(1.5)
adb("forward", f"tcp:{PORT}", f"tcp:{PORT}", check=True)

sock = None
for _ in range(120):
    try:
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=3)
        break
    except OSError:
        time.sleep(0.5)
if not sock:
    sys.exit("cannot connect to eyepiece_bridge")
sock.settimeout(None)
sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

stats = {"frames": 0, "lat": [], "dec": [], "gs": [], "drop": 0, "q": 0}
sent_at = {}


def reader():
    buf = b""
    while True:
        try:
            d = sock.recv(65536)
        except OSError:
            return
        if not d:
            return
        buf += d
        while len(buf) >= 8:
            _, _, t, _, n = struct.unpack_from("<BBBBI", buf)
            if len(buf) < 8 + n:
                break
            p, buf = buf[8:8 + n], buf[8 + n:]
            if t == 0x85:
                ver, fw, fh, dec, ht, _ = struct.unpack_from("<IHHBBH", p)
                print(f"INFO: proto v{ver}, fb {fw}x{fh}, decoder={['none','software','hardware'][dec] if dec < 3 else dec}, headtrack={ht}", flush=True)
            elif t == 0x83:
                print("LOG:", p.decode(errors="replace").strip(), flush=True)
            elif t == 0x84:
                pts, trecv, tshown, dec_us, conv_us, q, drop = struct.unpack_from("<QQQIIII", p)
                stats["frames"] += 1
                stats["dec"].append(dec_us)
                stats["gs"].append((tshown - trecv) / 1000)  # goggles: received -> shown, ms
                stats["drop"], stats["q"] = drop, q
                t0 = sent_at.pop(pts, None)
                if t0:  # PC send -> goggles "shown" ack received back (round trip incl. return)
                    stats["lat"].append((time.monotonic() - t0) * 1000)
            elif t == 0x81 and args.headtrack:
                _, yaw, pitch, roll, _, _, _ = struct.unpack_from("<QfffBBH", p)
                stats["pose"] = (yaw, pitch, roll)


threading.Thread(target=reader, daemon=True).start()

sock.sendall(msg(0x04, struct.pack("<HHBBH", W, H, 0, args.fps, 0)))
if args.headtrack:
    sock.sendall(msg(0x03, bytes([3, 1])))

SCKENC = not (args.x264 or args.vt or args.avf or args.source)
kbit = int((args.mbit or (40 if SCKENC else 20)) * 1000)
SCKCAP = __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "..", "bin", "sckcap")
SCKENC_BIN = SCKCAP.replace("sckcap", "sckenc")
if SCKENC:
    import os
    src = os.path.join(os.path.dirname(SCKCAP), "..", "scripts", "sckenc", "main.swift")
    if not os.path.exists(SCKENC_BIN) or os.path.getmtime(SCKENC_BIN) < os.path.getmtime(src):
        print("building bin/sckenc...", flush=True)
        subprocess.run(["swiftc", "-O", "-o", SCKENC_BIN, src], check=True)
        # Re-sign with a stable code-signing identity IF one is configured, so the macOS
        # Screen-Recording TCC grant survives the rebuild (a plain swiftc build is ad-hoc — new
        # cdhash → grant lost). Set env SCKENC_SIGN_ID to your signing identity (a cert SHA-1 or
        # its name). If unset, the binary stays ad-hoc — fine unless you depend on a persistent grant.
        sign_id = os.environ.get("SCKENC_SIGN_ID")
        if sign_id:
            subprocess.run(["codesign", "-s", sign_id, "--force", SCKENC_BIN], check=False)
enc = subprocess.Popen([SCKENC_BIN, str(W), str(H), str(args.fps), args.screen, str(kbit), str(args.gop), args.app],
                       stdout=subprocess.PIPE, bufsize=0, env={**__import__("os").environ, "SCKENC_STATS": "1"}) if SCKENC else None
cap = None if (args.source or args.avf or SCKENC) else subprocess.Popen(
    [SCKCAP, str(W), str(H), str(args.fps), args.screen], stdout=subprocess.PIPE)
ff = None if SCKENC else subprocess.Popen(
    ["ffmpeg", "-hide_banner", "-loglevel", "error",
     *(["-re", "-f", "lavfi", "-i", f"{args.source}=size={W}x{H}:rate={args.fps}"] if args.source else
       ["-f", "avfoundation", "-capture_cursor", "1", "-framerate", str(args.fps),
        "-pixel_format", "nv12", "-i", f"Capture screen {args.screen}"] if args.avf else
       ["-f", "rawvideo", "-pix_fmt", "nv12", "-s", f"{W}x{H}", "-r", str(args.fps), "-i", "-"]),
     "-vf", f"scale={W}:{H}:force_original_aspect_ratio=decrease,pad={W}:{H}:(ow-iw)/2:(oh-ih)/2",
     "-fps_mode", "cfr", "-r", str(args.fps),  # repeat frames when macOS sends none (idle screen)
     *(["-c:v", "h264_videotoolbox", "-realtime", "1", "-prio_speed", "1"] if args.vt else
       ["-c:v", "libx264", "-preset", args.preset, "-tune", "zerolatency", "-x264-params", "slices=1",
        "-pix_fmt", "yuv420p"]),
     "-profile:v", "high", "-bf", "0", "-g", str(args.gop or args.fps * 2),
     "-b:v", f"{kbit}k", "-maxrate", f"{kbit}k", "-bufsize", f"{kbit // 4}k",
     "-bsf:v", "h264_metadata=aud=insert", "-flush_packets", "1",
     "-f", "h264", "-"],
    stdin=cap.stdout if cap else None, stdout=subprocess.PIPE, bufsize=0)

AUD = b"\x00\x00\x00\x01\x09"


capsent = []  # capture -> sent ms (sckenc only)
rec = open(args.record, "wb") if args.record else None
reccsv = open(args.record + ".csv", "w") if args.record else None


def send_au(au, key=None, cap_ns=0):
    if key is None:
        key = any((au[i + 3] & 0x1F) == 5 for i in range(len(au) - 4)
                  if au[i] == 0 and au[i + 1] == 0 and au[i + 2] == 1)
    pts = int(time.monotonic() * 1e6)
    sent_at[pts] = time.monotonic()
    t_s = time.monotonic()
    sock.sendall(msg(0x01, struct.pack("<QB3x", pts, 0) + au, 1 if key else 0))
    if time.monotonic() - t_s > 0.04:
        print(f"STALL send to goggles (adb/USB) {(time.monotonic() - t_s) * 1000:.0f} ms", flush=True)
    if rec:
        rec.write(au)
        reccsv.write(f"{cap_ns},{time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)},{len(au)},{int(key)}\n")
    if cap_ns:
        capsent.append((time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) - cap_ns) / 1e6)


def read_exact(f, n):
    b = b""
    while len(b) < n:
        c = f.read(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


buf, n, t0, last = b"", 0, time.time(), time.time()
try:
    while True:
        if SCKENC:
            try:
                hdr = read_exact(enc.stdout, 25)
                ln, cap_ns, enc_ns, key = struct.unpack_from("<IQQB", hdr, 4)
                send_au(read_exact(enc.stdout, ln), bool(key), cap_ns)
            except EOFError:
                break
            n += 1
            chunk = b""
        else:
            chunk = ff.stdout.read(262144)
        if not chunk and not SCKENC:
            break
        buf += chunk
        while True:
            s = buf.find(AUD)
            e = buf.find(AUD, s + 5) if s >= 0 else -1
            if s < 0 or e < 0:
                break
            send_au(buf[s:e])
            buf = buf[e:]
            n += 1
        # ffmpeg writes a whole packet at once: if the pipe goes quiet for 2 ms, the AU in buf is
        # complete, so send it now instead of waiting ~1 frame for the next AUD.
        if buf.startswith(AUD) and len(buf) > 64 and not select.select([ff.stdout], [], [], 0.002)[0]:
            send_au(buf)
            buf = b""
            n += 1
        now = time.time()
        if now - last >= 3:
            lat, dec = stats["lat"][-100:], stats["dec"][-100:]
            el = now - last
            print(f"sent {n} AU | shown {stats['frames']} ({stats['frames']/el:.0f} fps) | "
                  + (f"cap->sent {sorted(capsent)[len(capsent)//2]:.0f}/{max(capsent):.0f} ms med/max | " if capsent else "")
                  + f"rtt {sorted(lat)[len(lat)//2] if lat else 0:.0f}/{max(lat) if lat else 0:.0f} ms med/max | "
                  f"goggles recv->shown {sorted(stats['gs'])[len(stats['gs'])//2] if stats['gs'] else 0:.0f} ms | "
                  f"decode {sorted(dec)[len(dec)//2]/1000 if dec else 0:.1f} ms | q {stats['q']} drop {stats['drop']}"
                  + (f" | pose {stats['pose']}" if "pose" in stats else ""), flush=True)
            stats["frames"], n, last = 0, 0, now
            stats["lat"].clear(); stats["dec"].clear(); stats["gs"].clear(); capsent.clear()
            if len(sent_at) > 2000:
                sent_at.clear()
        if args.secs and now - t0 > args.secs:
            break
except (BrokenPipeError, ConnectionResetError) as e:
    print("connection lost:", e)
finally:
    for p in (ff, enc):
        if p:
            p.kill()
    if cap:
        cap.kill()
    try:
        sock.sendall(msg(0x03, bytes([2])))  # QUIT
    except OSError:
        pass
    sock.close()
    if bridge:
        time.sleep(0.5)
        adb("shell", f"pkill -f {BRIDGE}; true")
        bridge.kill()
    print("stopped")
