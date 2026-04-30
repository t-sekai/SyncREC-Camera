from __future__ import annotations

import asyncio
import queue
import threading
from typing import Any

from .models import timestamp_now

try:
    from bleak import BleakClient, BleakScanner
except Exception as exc:  # pragma: no cover - runtime guard
    BleakClient = None
    BleakScanner = None
    BLEAK_IMPORT_ERROR = exc
else:
    BLEAK_IMPORT_ERROR = None


TENTACLE_TIMECODE_CHAR_UUID = "0dab144c-2cb9-11e6-b67b-9e71128cae77"


def decode_tentacle_timecode(data: bytes) -> dict[str, Any] | None:
    if len(data) < 5:
        return None

    fps = int(data[0])
    hours = int(data[1])
    minutes = int(data[2])
    seconds = int(data[3])
    frames = int(data[4])
    if hours >= 24 or minutes >= 60 or seconds >= 60:
        return None

    return {
        "fps": fps,
        "hours": hours,
        "minutes": minutes,
        "seconds": seconds,
        "frames": frames,
        "timecode": f"{hours:02d}:{minutes:02d}:{seconds:02d}:{frames:02d}",
        "raw": data.hex(),
    }


class TentacleReader:
    def __init__(self, event_queue: queue.Queue[tuple[str, Any]]):
        self.event_queue = event_queue
        self._loop: asyncio.AbstractEventLoop | None = None
        self._loop_thread: threading.Thread | None = None
        self._running = False
        self._target_name = "NeuROK"
        self._client: BleakClient | None = None

    @property
    def is_running(self) -> bool:
        return self._running and self._loop is not None and self._loop.is_running()

    def start(self, target_name: str) -> None:
        if BleakScanner is None or BleakClient is None:
            self.log(
                "Tentacle monitoring unavailable: missing dependency 'bleak'. "
                f"Install with: pip install bleak (import error: {BLEAK_IMPORT_ERROR})"
            )
            return
        if self.is_running:
            self.log("Tentacle reader already running.")
            return

        self._target_name = target_name.strip() or "NeuROK"
        self._running = True
        self._loop_thread = threading.Thread(target=self._run_loop, daemon=True)
        self._loop_thread.start()
        self._emit_state(f"starting ({self._target_name})")

    def stop(self) -> None:
        self._running = False
        loop = self._loop
        if not loop:
            self._emit_state("stopped")
            return

        async def _shutdown() -> None:
            client = self._client
            if client is not None:
                try:
                    if client.is_connected:
                        await client.disconnect()
                except Exception:
                    pass

        fut = asyncio.run_coroutine_threadsafe(_shutdown(), loop)
        try:
            fut.result(timeout=5)
        except Exception:
            pass

        loop.call_soon_threadsafe(loop.stop)
        self._loop = None
        self._emit_state("stopped")

    def log(self, message: str) -> None:
        self.event_queue.put(("log", f"[{timestamp_now()}] {message}"))

    def _emit_state(self, state: str) -> None:
        self.event_queue.put(("tentacle_state", {"state": state}))

    def _emit_timecode(self, packet: dict[str, Any]) -> None:
        self.event_queue.put(("tentacle_timecode", packet))

    def _run_loop(self) -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        self._loop = loop

        main_task = loop.create_task(self._run_reader())
        try:
            loop.run_forever()
        finally:
            main_task.cancel()
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
            loop.close()

    async def _run_reader(self) -> None:
        while self._running:
            try:
                device = await self._find_device(self._target_name)
                if not device:
                    self._emit_state(f"not found ({self._target_name})")
                    await asyncio.sleep(1.0)
                    continue
                await self._connect_and_stream(device)
            except asyncio.CancelledError:
                break
            except Exception as exc:
                self.log(f"Tentacle reader error: {exc}")
                self._emit_state(f"error: {exc}")
                await asyncio.sleep(1.0)

    async def _find_device(self, target_name: str) -> Any | None:
        self._emit_state(f"scanning ({target_name})")
        devices = await BleakScanner.discover(timeout=6.0)
        target_folded = target_name.casefold()

        exact_match = None
        partial_match = None
        for device in devices:
            name = (device.name or "").strip()
            if not name:
                continue
            folded = name.casefold()
            if folded == target_folded:
                exact_match = device
                break
            if target_folded in folded and partial_match is None:
                partial_match = device
        return exact_match or partial_match

    async def _connect_and_stream(self, device: Any) -> None:
        device_name = (device.name or self._target_name).strip()
        self._emit_state(f"connecting ({device_name})")
        self.log(f"Tentacle connect: {device_name}")

        async with BleakClient(device) as client:
            self._client = client
            self._emit_state(f"connected ({device_name})")
            self.log(f"Tentacle connected: {device_name}")

            try:
                initial = await client.read_gatt_char(TENTACLE_TIMECODE_CHAR_UUID)
                decoded = decode_tentacle_timecode(bytes(initial))
                if decoded:
                    self._emit_timecode(decoded)
            except Exception as exc:
                self.log(f"Tentacle initial read failed: {exc}")

            def notification_handler(_: Any, data: Any) -> None:
                decoded = decode_tentacle_timecode(bytes(data))
                if decoded:
                    self._emit_timecode(decoded)

            await client.start_notify(TENTACLE_TIMECODE_CHAR_UUID, notification_handler)
            try:
                while self._running and client.is_connected:
                    await asyncio.sleep(0.5)
            finally:
                try:
                    await client.stop_notify(TENTACLE_TIMECODE_CHAR_UUID)
                except Exception:
                    pass
                self._client = None
                if self._running:
                    self._emit_state(f"reconnecting ({device_name})")
