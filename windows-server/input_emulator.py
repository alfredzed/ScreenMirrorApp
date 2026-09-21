"""
input_emulator.py
------------------
iPadから送られる正規化座標(0.0〜1.0、黒帯を除いた映像コンテンツ領域基準)とジェスチャー種別を
Windowsの実画面座標・マウス操作に変換する。

正規化座標は capture.Geometry.content_rect（ソース画面座標系での実コンテンツ矩形）を用いて
実画面ピクセル座標へ復元する。これにより fit（レターボックス）/ fill（クロップ）の
どちらの表示モードでもタッチ位置のズレが生じない。
"""
from __future__ import annotations

import pyautogui

from capture import Geometry
from protocol import DragMsg, GestureMsg, ScrollMsg

# pyautogui側のフェイルセーフ（画面端に一瞬でも移動すると例外で止まる機能）は
# リモート操作の性質上、意図しない停止を招くため無効化する。
pyautogui.FAILSAFE = False
pyautogui.PAUSE = 0.0

# 2本指スワイプの正規化量(dx/dy)を実際のスクロール量へ変換する係数。
# 値が大きいほど少ないスワイプで大きくスクロールする。要調整パラメータ。
SCROLL_SENSITIVITY = 800


class InputEmulator:
    def __init__(self):
        self._geometry: Geometry | None = None
        self._dragging = False

    def update_geometry(self, geometry: Geometry) -> None:
        self._geometry = geometry

    def _to_screen_coords(self, x: float, y: float) -> tuple[int, int]:
        if self._geometry is None:
            raise RuntimeError("Geometry未設定のまま入力を受信しました")
        r = self._geometry.content_rect
        screen_x = self._geometry.source_left + r.x + x * r.w
        screen_y = self._geometry.source_top + r.y + y * r.h
        # クランプ（映像端の丸め誤差でソース範囲を超えないようにする）
        screen_x = max(
            self._geometry.source_left,
            min(self._geometry.source_left + self._geometry.source_w - 1, screen_x),
        )
        screen_y = max(
            self._geometry.source_top,
            min(self._geometry.source_top + self._geometry.source_h - 1, screen_y),
        )
        return int(round(screen_x)), int(round(screen_y))

    def handle_gesture(self, msg: GestureMsg) -> None:
        sx, sy = self._to_screen_coords(msg.x, msg.y)
        if msg.gesture == "tap":
            pyautogui.click(x=sx, y=sy, button="left")
        elif msg.gesture == "right_tap":
            pyautogui.click(x=sx, y=sy, button="right")

    def handle_drag(self, msg: DragMsg) -> None:
        sx, sy = self._to_screen_coords(msg.x, msg.y)
        if msg.phase == "begin":
            pyautogui.moveTo(sx, sy)
            pyautogui.mouseDown(button="left")
            self._dragging = True
        elif msg.phase == "move":
            pyautogui.moveTo(sx, sy)
        elif msg.phase == "end":
            pyautogui.moveTo(sx, sy)
            if self._dragging:
                pyautogui.mouseUp(button="left")
            self._dragging = False

    def handle_scroll(self, msg: ScrollMsg) -> None:
        # dx, dy は正規化された相対量。垂直スクロールを優先し、水平は必要に応じて拡張。
        v_amount = int(round(-msg.dy * SCROLL_SENSITIVITY))
        h_amount = int(round(msg.dx * SCROLL_SENSITIVITY))
        if v_amount != 0:
            pyautogui.scroll(v_amount)
        if h_amount != 0:
            pyautogui.hscroll(h_amount)

    def reset(self) -> None:
        """クライアント切断時などにドラッグ状態が残らないようにする。"""
        if self._dragging:
            try:
                pyautogui.mouseUp(button="left")
            except Exception:
                pass
        self._dragging = False
