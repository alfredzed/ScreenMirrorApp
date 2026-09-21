"""
protocol.py
-----------
README.md の「3. データフォーマット仕様」に準拠した
JSONメッセージのビルド/パースと、バイナリ映像フレームのパッキングを提供する。
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Optional

# --- バイナリ映像フレームのヘッダー ---
FRAME_HEADER_KEYFRAME = b"\x01"
FRAME_HEADER_DELTA = b"\x00"


def pack_video_frame(data: bytes, is_keyframe: bool) -> bytes:
    """README 3.2 のフォーマットで H.264 Annex-B データにヘッダーを付与する。"""
    header = FRAME_HEADER_KEYFRAME if is_keyframe else FRAME_HEADER_DELTA
    return header + data


# --- JSONメッセージ ---
def build_video_info(width: int, height: int, fps: int, keyframe_interval: int) -> str:
    return json.dumps(
        {
            "type": "video_info",
            "width": width,
            "height": height,
            "fps": fps,
            "codec": "h264",
            "keyframe_interval": keyframe_interval,
        }
    )


def build_pong(t: Any) -> str:
    return json.dumps({"type": "pong", "t": t})


def build_ping() -> str:
    return json.dumps({"type": "ping", "t": int(time.time() * 1000)})


@dataclass
class Handshake:
    device: str
    aspect_ratio: float
    display_mode: str  # "fit" | "fill"
    max_fps: int = 60


def parse_handshake(msg: dict) -> Handshake:
    return Handshake(
        device=msg.get("device", "unknown"),
        aspect_ratio=float(msg["aspect_ratio"]),
        display_mode=msg.get("display_mode", "fit"),
        max_fps=int(msg.get("max_fps", 60)),
    )


@dataclass
class GestureMsg:
    gesture: str  # "tap" | "right_tap"
    x: float
    y: float


@dataclass
class DragMsg:
    phase: str  # "begin" | "move" | "end"
    x: float
    y: float


@dataclass
class ScrollMsg:
    dx: float
    dy: float
    phase: str  # "began" | "changed" | "ended"


def parse_message(raw: str) -> Optional[Any]:
    """受信したJSONテキストフレームを種別ごとのオブジェクトへ変換する。"""
    try:
        msg = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None

    msg_type = msg.get("type")
    if msg_type == "handshake":
        return parse_handshake(msg)
    if msg_type == "gesture":
        return GestureMsg(gesture=msg["gesture"], x=float(msg["x"]), y=float(msg["y"]))
    if msg_type == "drag":
        return DragMsg(phase=msg["phase"], x=float(msg["x"]), y=float(msg["y"]))
    if msg_type == "scroll":
        return ScrollMsg(
            dx=float(msg.get("dx", 0.0)),
            dy=float(msg.get("dy", 0.0)),
            phase=msg.get("phase", "changed"),
        )
    if msg_type == "ping":
        return ("ping", msg.get("t"))
    if msg_type == "pong":
        return ("pong", msg.get("t"))
    return None
