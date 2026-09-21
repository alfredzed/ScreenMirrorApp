"""Low-latency H.264 encoder with automatic GPU fallback."""
from __future__ import annotations

from fractions import Fraction
from typing import Iterator, Tuple

import av
import numpy as np


BACKEND_CODECS = {
    "nvenc": "h264_nvenc",
    "qsv": "h264_qsv",
    "amf": "h264_amf",
    "x264": "libx264",
}
AUTO_ORDER = ("nvenc", "qsv", "amf", "x264")


class H264Encoder:
    def __init__(self, width: int, height: int, fps: int = 60,
                 gop_size: int = 60, bitrate: int = 8_000_000,
                 backend: str = "auto"):
        self.width = width
        self.height = height
        self.fps = fps
        self.gop_size = gop_size
        self.bitrate = bitrate
        self._frame_index = 0
        self._codec = None
        self.backend = ""

        if backend != "auto" and backend not in BACKEND_CODECS:
            raise ValueError(f"Unknown encoder backend: {backend}")
        self._remaining = list(AUTO_ORDER if backend == "auto" else (backend,))
        self._open_next_backend()

    @staticmethod
    def available_backends() -> list[str]:
        available = av.codecs_available
        return [name for name, codec in BACKEND_CODECS.items() if codec in available]

    def _configure(self, backend: str):
        codec = av.CodecContext.create(BACKEND_CODECS[backend], "w")
        codec.width = self.width
        codec.height = self.height
        codec.framerate = Fraction(self.fps, 1)
        codec.time_base = Fraction(1, self.fps)
        codec.gop_size = self.gop_size
        codec.max_b_frames = 0
        codec.bit_rate = self.bitrate
        codec.pix_fmt = "yuv420p" if backend == "x264" else "nv12"

        if backend == "nvenc":
            codec.options = {
                "preset": "p1", "tune": "ull", "rc": "cbr",
                "zerolatency": "1", "delay": "0", "bf": "0",
                "forced-idr": "1",
            }
        elif backend == "qsv":
            codec.options = {
                "preset": "veryfast", "async_depth": "1",
                "look_ahead": "0", "bf": "0",
            }
        elif backend == "amf":
            codec.options = {
                "usage": "ultralowlatency", "quality": "speed",
                "rc": "cbr", "bf": "0",
            }
        else:
            codec.options = {
                "preset": "ultrafast",
                "tune": "zerolatency",
                "x264-params": (
                    f"keyint={self.gop_size}:min-keyint={self.gop_size}:"
                    "scenecut=0:repeat-headers=1"
                ),
            }
        codec.open()
        return codec

    def _open_next_backend(self) -> None:
        errors: list[str] = []
        while self._remaining:
            candidate = self._remaining.pop(0)
            try:
                self._codec = self._configure(candidate)
                self.backend = candidate
                print(f"[ScreenMirrorApp] encoder={candidate} ({BACKEND_CODECS[candidate]})")
                return
            except Exception as exc:
                errors.append(f"{candidate}: {exc}")
        raise RuntimeError("No H.264 encoder could be opened: " + " | ".join(errors))

    def request_keyframe(self) -> None:
        self._frame_index = 0

    def _encode_once(self, frame_bgr: np.ndarray):
        assert self._codec is not None
        frame = av.VideoFrame.from_ndarray(frame_bgr, format="bgr24")
        frame = frame.reformat(format=self._codec.pix_fmt)
        if self._frame_index % self.gop_size == 0:
            frame.pict_type = av.video.frame.PictureType.I
        self._frame_index += 1
        return list(self._codec.encode(frame))

    def encode(self, frame_bgr: np.ndarray) -> Iterator[Tuple[bytes, bool]]:
        while True:
            try:
                packets = self._encode_once(frame_bgr)
                break
            except Exception as exc:
                if not self._remaining:
                    raise
                print(f"[ScreenMirrorApp] encoder {self.backend} failed: {exc}; falling back")
                self.close()
                self._frame_index = 0
                self._open_next_backend()
        for packet in packets:
            yield bytes(packet), bool(packet.is_keyframe)

    def flush(self) -> Iterator[Tuple[bytes, bool]]:
        if self._codec is None:
            return
        for packet in self._codec.encode(None):
            yield bytes(packet), bool(packet.is_keyframe)

    def close(self) -> None:
        if self._codec is None:
            return
        try:
            list(self.flush())
        except Exception:
            pass
        self._codec = None
