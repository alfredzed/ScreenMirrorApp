"""USBMux transport for a direct Windows <-> iPad USB cable connection."""
from __future__ import annotations

import asyncio
import subprocess
import time
from pathlib import Path

KIND_JSON = 0x01
KIND_VIDEO = 0x02
MAX_FRAME_SIZE = 64 * 1024 * 1024


def pack_usb_frame(kind: int, payload: bytes) -> bytes:
    body = bytes((kind,)) + payload
    return len(body).to_bytes(4, "big") + body


class UsbPeer:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer

    async def recv(self) -> str | bytes:
        header = await self.reader.readexactly(4)
        length = int.from_bytes(header, "big")
        if length < 1 or length > MAX_FRAME_SIZE:
            raise ValueError(f"invalid USB frame length: {length}")
        body = await self.reader.readexactly(length)
        if body[0] == KIND_JSON:
            return body[1:].decode("utf-8")
        return body[1:]

    async def send(self, payload: str | bytes) -> None:
        if isinstance(payload, str):
            frame = pack_usb_frame(KIND_JSON, payload.encode("utf-8"))
        else:
            frame = pack_usb_frame(KIND_VIDEO, bytes(payload))
        self.writer.write(frame)
        await self.writer.drain()

    async def close(self) -> None:
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except Exception:
            pass


class UsbMuxProxy:
    def __init__(self, executable: str, local_port: int, device_port: int, udid: str = ""):
        self.executable = str(Path(executable))
        self.local_port = local_port
        self.device_port = device_port
        self.udid = udid
        self.process: subprocess.Popen | None = None

    def start(self) -> None:
        if self.process and self.process.poll() is None:
            return
        modern = [self.executable]
        if self.udid:
            modern += ["-u", self.udid]
        modern += [f"{self.local_port}:{self.device_port}"]
        separate = [self.executable]
        if self.udid:
            separate += ["-u", self.udid]
        separate += [str(self.local_port), str(self.device_port)]
        legacy = [self.executable, str(self.local_port), str(self.device_port)]
        if self.udid:
            legacy.append(self.udid)

        last_error = ""
        for command in (modern, separate, legacy):
            try:
                proc = subprocess.Popen(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                )
                time.sleep(0.5)
                if proc.poll() is None:
                    self.process = proc
                    print(f"[ScreenMirrorApp] iproxy started on 127.0.0.1:{self.local_port}")
                    return
                last_error = f"exit code {proc.returncode}"
            except Exception as exc:
                last_error = str(exc)
        raise RuntimeError(f"iproxy could not be started: {last_error}")

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None
