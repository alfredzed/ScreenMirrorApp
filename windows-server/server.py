"""ScreenMirrorApp 1.03 Windows server: Wi-Fi and direct USB, GPU aware."""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

import websockets
from websockets.exceptions import ConnectionClosed

from capture import Geometry, ScreenCapturer, compute_geometry, render_output_frame
from encoder import H264Encoder
from input_emulator import InputEmulator
from protocol import (
    DragMsg, GestureMsg, Handshake, ScrollMsg, build_pong, build_video_info,
    pack_video_frame, parse_message,
)
from usb_transport import UsbMuxProxy, UsbPeer

HOST = "0.0.0.0"
WS_PORT = 8765
USB_PORT = 27183
TARGET_FPS = 60
GOP_SIZE = 60
MAX_OUTPUT_WIDTH = 1920
HANDSHAKE_TIMEOUT_SEC = 10

capturer: ScreenCapturer | None = None
options = None


async def video_sender(peer, encoder: H264Encoder, geometry: Geometry,
                       display_mode: str, fps: int) -> None:
    assert capturer is not None
    loop = asyncio.get_running_loop()
    interval = 1.0 / fps
    while True:
        started = time.monotonic()
        frame = await loop.run_in_executor(None, capturer.get_frame)
        if frame is None:
            await asyncio.sleep(0.001)
            continue
        output = await loop.run_in_executor(
            None, render_output_frame, frame, geometry, display_mode
        )
        packets = await loop.run_in_executor(None, lambda: list(encoder.encode(output)))
        for data, is_keyframe in packets:
            await peer.send(pack_video_frame(data, is_keyframe))
        remaining = interval - (time.monotonic() - started)
        if remaining > 0:
            await asyncio.sleep(remaining)


async def message_receiver(peer, input_emulator: InputEmulator) -> None:
    while True:
        raw = await peer.recv()
        if isinstance(raw, (bytes, bytearray)):
            continue
        msg = parse_message(raw)
        if isinstance(msg, GestureMsg):
            input_emulator.handle_gesture(msg)
        elif isinstance(msg, DragMsg):
            input_emulator.handle_drag(msg)
        elif isinstance(msg, ScrollMsg):
            input_emulator.handle_scroll(msg)
        elif isinstance(msg, tuple) and msg[0] == "ping":
            await peer.send(build_pong(msg[1]))


async def session_handler(peer, transport_name: str) -> None:
    assert capturer is not None and options is not None
    input_emulator = InputEmulator()
    encoder = None
    try:
        raw = await asyncio.wait_for(peer.recv(), timeout=HANDSHAKE_TIMEOUT_SEC)
        msg = parse_message(raw)
        if not isinstance(msg, Handshake):
            raise ValueError("first message must be handshake")

        source_left, source_top, source_w, source_h = capturer.get_source_bounds()
        geometry = compute_geometry(
            source_w, source_h, msg.aspect_ratio, msg.display_mode,
            options.max_width, source_left, source_top,
        )
        input_emulator.update_geometry(geometry)
        fps = min(msg.max_fps, options.fps)
        encoder = H264Encoder(
            geometry.output_w, geometry.output_h, fps=fps,
            gop_size=options.gop, bitrate=options.bitrate,
            backend=options.encoder,
        )
        print(
            f"[ScreenMirrorApp] {transport_name} connected; "
            f"{geometry.output_w}x{geometry.output_h}@{fps}, encoder={encoder.backend}"
        )
        await peer.send(build_video_info(geometry.output_w, geometry.output_h, fps, options.gop))

        sender = asyncio.create_task(video_sender(peer, encoder, geometry, msg.display_mode, fps))
        receiver = asyncio.create_task(message_receiver(peer, input_emulator))
        done, pending = await asyncio.wait((sender, receiver), return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        for task in done:
            exc = task.exception()
            if exc:
                raise exc
    except (asyncio.TimeoutError, asyncio.IncompleteReadError,
            ConnectionError, ConnectionClosed):
        pass
    except Exception as exc:
        print(f"[ScreenMirrorApp] {transport_name} session ended: {exc}")
    finally:
        input_emulator.reset()
        if encoder:
            encoder.close()
        close = getattr(peer, "close", None)
        if close and transport_name == "USB":
            await close()


async def websocket_handler(websocket) -> None:
    await session_handler(websocket, "Wi-Fi/LAN")


async def usb_connector_loop() -> None:
    assert options is not None
    while True:
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", options.usb_port)
            await session_handler(UsbPeer(reader, writer), "USB")
        except (ConnectionError, OSError):
            await asyncio.sleep(1.0)
        except asyncio.CancelledError:
            raise


def find_iproxy(explicit: str) -> str | None:
    if explicit:
        return explicit if Path(explicit).is_file() else None
    roots = [Path(__file__).resolve().parent]
    if getattr(sys, "frozen", False):
        roots.insert(0, Path(sys.executable).resolve().parent)
    candidates = tuple(
        candidate
        for root in roots
        for candidate in (
            root / "tools" / "iproxy.exe",
            root / "tools" / "iproxy" / "iproxy.exe",
            root / "tools" / "libimobiledevice-1.2.1" / "iproxy.exe",
        )
    )
    return next((str(path) for path in candidates if path.is_file()), None)


def parse_args():
    parser = argparse.ArgumentParser(description="ScreenMirrorApp Windows server")
    parser.add_argument("--transport", choices=("auto", "wifi", "usb"), default="auto")
    parser.add_argument("--encoder", choices=("auto", "nvenc", "qsv", "amf", "x264"), default="auto")
    parser.add_argument("--port", type=int, default=WS_PORT)
    parser.add_argument("--usb-port", type=int, default=USB_PORT)
    parser.add_argument("--iproxy", default="", help="path to iproxy.exe")
    parser.add_argument("--udid", default="", help="optional target iPad UDID")
    parser.add_argument("--fps", type=int, choices=(30, 60), default=60)
    parser.add_argument("--gop", type=int, default=60)
    parser.add_argument("--bitrate", type=int, default=8_000_000)
    parser.add_argument("--max-width", type=int, default=1920)
    parser.add_argument(
        "--monitor", type=int, default=1,
        help="mss monitor index (1=primary/first, 2=virtual/second when present)",
    )
    return parser.parse_args()


async def main() -> None:
    global capturer
    assert options is not None
    capturer = ScreenCapturer(target_fps=options.fps, monitor_index=options.monitor)
    proxy = None
    tasks = []
    try:
        if options.transport in ("auto", "usb"):
            iproxy = find_iproxy(options.iproxy)
            if iproxy:
                proxy = UsbMuxProxy(iproxy, options.usb_port, options.usb_port, options.udid)
                proxy.start()
                tasks.append(asyncio.create_task(usb_connector_loop()))
            elif options.transport == "usb":
                raise RuntimeError("USB mode requires iproxy.exe (--iproxy PATH or tools\\iproxy.exe)")
            else:
                print("[ScreenMirrorApp] iproxy.exe not found; USB disabled, Wi-Fi remains available")

        if options.transport in ("auto", "wifi"):
            print(f"[ScreenMirrorApp] listening on ws://{HOST}:{options.port}/stream")
            server = await websockets.serve(
                websocket_handler, HOST, options.port, max_size=None,
                compression=None, ping_interval=None,
            )
            tasks.append(asyncio.create_task(server.wait_closed()))

        if not tasks:
            raise RuntimeError("no transport was started")
        await asyncio.gather(*tasks)
    finally:
        for task in tasks:
            task.cancel()
        if proxy:
            proxy.stop()


if __name__ == "__main__":
    options = parse_args()
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    finally:
        if capturer is not None:
            capturer.close()
