"""
capture.py
----------
Windows画面のキャプチャ（dxcam優先・mssフォールバック）と、
iPad側の aspect_ratio / display_mode に応じたリサイズ・レターボックス/クロップ処理。

「content_rect」は、出力映像のうち黒帯を除いた実コンテンツ領域が
"キャプチャ元画面のどの矩形に対応するか" を表す。
InputEmulator はこの content_rect を使って正規化座標を実画面座標へ復元する。
"""
from __future__ import annotations

import ctypes
import time
from dataclasses import dataclass
from typing import Optional, Tuple

import cv2
import numpy as np

try:
    import dxcam  # type: ignore

    _HAS_DXCAM = True
except ImportError:
    _HAS_DXCAM = False

import mss


class _Point(ctypes.Structure):
    _fields_ = (("x", ctypes.c_long), ("y", ctypes.c_long))


class _CursorInfo(ctypes.Structure):
    _fields_ = (
        ("cbSize", ctypes.c_uint),
        ("flags", ctypes.c_uint),
        ("hCursor", ctypes.c_void_p),
        ("ptScreenPos", _Point),
    )


@dataclass
class Rect:
    x: int
    y: int
    w: int
    h: int


@dataclass
class Geometry:
    source_w: int
    source_h: int
    output_w: int
    output_h: int
    content_rect: Rect  # ソース画面座標系での「黒帯を除いた実コンテンツ」矩形
    source_left: int = 0  # Windows仮想デスクトップ上のモニター原点
    source_top: int = 0


def compute_geometry(
    source_w: int,
    source_h: int,
    aspect_ratio: float,
    display_mode: str,
    max_output_width: int = 1920,
    source_left: int = 0,
    source_top: int = 0,
) -> Geometry:
    """
    iPadが通知した aspect_ratio(width/height) と display_mode に応じて、
    出力解像度と、ソース画面上のコンテンツ矩形を計算する。

    - fit  : ソース全体を維持しつつ、目標アスペクト比になるよう黒帯(パディング)を追加。
             content_rect はソース全体 = (0, 0, source_w, source_h)。
    - fill : 目標アスペクト比に合わせてソースを中央基準でクロップし、黒帯なしで全面表示。
             content_rect はクロップ後のソース内矩形。
    """
    source_aspect = source_w / source_h

    if display_mode == "fill":
        if source_aspect > aspect_ratio:
            crop_w = int(round(source_h * aspect_ratio))
            crop_h = source_h
        else:
            crop_w = source_w
            crop_h = int(round(source_w / aspect_ratio))
        crop_x = (source_w - crop_w) // 2
        crop_y = (source_h - crop_h) // 2
        content_rect = Rect(crop_x, crop_y, crop_w, crop_h)
        out_w = min(max_output_width, crop_w)
        out_h = int(round(out_w / aspect_ratio))
    else:
        content_rect = Rect(0, 0, source_w, source_h)
        out_w = min(max_output_width, source_w)
        out_h = int(round(out_w / aspect_ratio))

    out_w -= out_w % 2
    out_h -= out_h % 2

    return Geometry(
        source_w, source_h, out_w, out_h, content_rect,
        source_left=source_left, source_top=source_top,
    )


def render_output_frame(frame_bgr: np.ndarray, geometry: Geometry, display_mode: str) -> np.ndarray:
    """ソースフレームを Geometry に基づき出力用フレーム(BGR, out_w x out_h)へ変換する。"""
    if display_mode == "fill":
        r = geometry.content_rect
        cropped = frame_bgr[r.y : r.y + r.h, r.x : r.x + r.w]
        resized = cv2.resize(cropped, (geometry.output_w, geometry.output_h), interpolation=cv2.INTER_AREA)
        return resized

    src_h, src_w = frame_bgr.shape[:2]
    target_aspect = geometry.output_w / geometry.output_h
    src_aspect = src_w / src_h

    if src_aspect > target_aspect:
        inner_w = geometry.output_w
        inner_h = int(round(inner_w / src_aspect))
    else:
        inner_h = geometry.output_h
        inner_w = int(round(inner_h * src_aspect))

    inner_w -= inner_w % 2
    inner_h -= inner_h % 2
    resized = cv2.resize(frame_bgr, (inner_w, inner_h), interpolation=cv2.INTER_AREA)

    canvas = np.zeros((geometry.output_h, geometry.output_w, 3), dtype=np.uint8)
    off_x = (geometry.output_w - inner_w) // 2
    off_y = (geometry.output_h - inner_h) // 2
    canvas[off_y : off_y + inner_h, off_x : off_x + inner_w] = resized
    return canvas


class ScreenCapturer:
    """dxcam優先、失敗時は mss にフォールバックするキャプチャラッパー。"""

    def __init__(self, target_fps: int = 60, monitor_index: int = 1):
        self.target_fps = target_fps
        self.monitor_index = monitor_index
        self._backend = None
        self._mss = None
        self._use_dxcam = False
        self._init_backend()

    def _init_backend(self) -> None:
        # dxcamはDesktop Duplication APIのネイティブクラッシュが不安定なため、
        # 当面mssに固定する。
        self._use_dxcam = False
        self._mss = mss.mss()
        available = len(self._mss.monitors) - 1
        if self.monitor_index < 1 or self.monitor_index > available:
            raise ValueError(
                f"monitor {self.monitor_index} is unavailable; choose 1..{available}"
            )
        selected = self._mss.monitors[self.monitor_index]
        print(
            f"[ScreenMirrorApp] capture=mss monitor={self.monitor_index} "
            f"{selected['width']}x{selected['height']} "
            f"at ({selected['left']},{selected['top']})"
        )

    def get_source_size(self) -> Tuple[int, int]:
        if self._use_dxcam:
            frame = self._backend.get_latest_frame()
            if frame is not None:
                h, w = frame.shape[:2]
                return w, h
            info = self._backend.output_res
            return info[0], info[1]
        monitor = self._mss.monitors[self.monitor_index]
        return monitor["width"], monitor["height"]

    def get_source_bounds(self) -> Tuple[int, int, int, int]:
        monitor = self._mss.monitors[self.monitor_index]
        return monitor["left"], monitor["top"], monitor["width"], monitor["height"]

    def get_frame(self) -> Optional[np.ndarray]:
        """BGRのnumpy配列(H, W, 3)を返す。取得できなければNone。"""
        if self._use_dxcam:
            frame = self._backend.get_latest_frame()
            return frame
        monitor = self._mss.monitors[self.monitor_index]
        shot = self._mss.grab(monitor)
        frame = np.array(shot)
        frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
        self._draw_cursor(frame, monitor)
        return frame

    @staticmethod
    def _draw_cursor(frame: np.ndarray, monitor: dict) -> None:
        """MSSが含めないWindowsカーソルを低コストな矢印として合成する。"""
        info = _CursorInfo()
        info.cbSize = ctypes.sizeof(_CursorInfo)
        user32 = ctypes.windll.user32
        if not user32.GetCursorInfo(ctypes.byref(info)) or not (info.flags & 0x1):
            return
        x = int(info.ptScreenPos.x - monitor["left"])
        y = int(info.ptScreenPos.y - monitor["top"])
        if not (0 <= x < monitor["width"] and 0 <= y < monitor["height"]):
            return
        arrow = np.array(
            [[0, 0], [0, 23], [6, 17], [11, 27], [15, 25], [10, 15], [18, 15]],
            dtype=np.int32,
        )
        arrow[:, 0] += x
        arrow[:, 1] += y
        cv2.fillPoly(frame, [arrow], (255, 255, 255), lineType=cv2.LINE_AA)
        cv2.polylines(frame, [arrow], True, (0, 0, 0), 2, lineType=cv2.LINE_AA)

    def close(self) -> None:
        if self._use_dxcam and self._backend is not None:
            try:
                self._backend.stop()
            except Exception:
                pass
        if self._mss is not None:
            self._mss.close()
