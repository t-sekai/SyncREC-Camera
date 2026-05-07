from __future__ import annotations

import asyncio
import json
import queue
import threading
import time
import uuid
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from .models import DeviceState, timestamp_now, to_float_or_none, to_int_or_none

try:
    import websockets
    from websockets.server import WebSocketServerProtocol
except Exception as exc:  # pragma: no cover - runtime guard
    raise SystemExit(
        "Missing dependency: websockets\n"
        "Install with: pip install websockets\n"
        f"Import error: {exc}"
    )


@dataclass
class PullVideosRequest:
    device_id: str
    payload: dict[str, Any]


@dataclass
class PreviewPhotoRequest:
    device_id: str
    request_id: str
    batch_id: str
    attempt: int
    started_unix: float
    image_path: str = ""
    metadata_path: str = ""
    timeout_task: asyncio.Task | None = None


class DirectorServer:
    HEARTBEAT_TIMEOUT_SECONDS = 45.0
    HEARTBEAT_CHECK_SECONDS = 5.0

    def __init__(self, event_queue: queue.Queue[tuple[str, Any]]):
        self.event_queue = event_queue
        self._server = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._loop_thread: threading.Thread | None = None
        self._host = "0.0.0.0"
        self._port = 8765
        self.devices: dict[WebSocketServerProtocol, DeviceState] = {}
        self._lock = threading.Lock()
        self._heartbeat_task: asyncio.Task | None = None
        self._time_sync_task: asyncio.Task | None = None

        # Serialized pull-videos queue. Only one iPhone gets a pull command at a time.
        self._pull_queue: deque[PullVideosRequest] = deque()
        self._active_pull: PullVideosRequest | None = None
        self._ack_waiters: dict[tuple[str, str], asyncio.Future] = {}

        self._preview_upload_url = ""
        self._preview_timeout_seconds = 35.0
        self._preview_max_retries = 1
        self._preview_batch_size = 5
        self._preview_requests: dict[tuple[str, str], PreviewPhotoRequest] = {}
        self._preview_current_request_by_device: dict[str, str] = {}

        # Director-side anchor derived from the single Tentacle BLE reader.
        self._time_sync_sequence = 0
        self._timecode_anchor_monotonic: float | None = None
        self._timecode_anchor_total_frames: int | None = None
        self._timecode_anchor_fps: int | None = None
        self._timecode_anchor_source = "tentacle_sync_e"
        self._time_source = "laptop"
        self._laptop_timecode_fps = 30

        self._camera_param_preset: dict[str, Any] | None = None
        self._camera_param_preset_path: Path | None = None
        self._preset_dir = Path("camera_param_presets")
        self._sync_report_dir = Path("camera_param_sync_reports")

    @property
    def is_running(self) -> bool:
        return self._loop is not None and self._loop.is_running()

    def start(self, host: str, port: int) -> None:
        if self.is_running:
            self.log("Server already running.")
            return

        self._host = host
        self._port = port

        self._loop_thread = threading.Thread(target=self._run_loop, daemon=True)
        self._loop_thread.start()
        self.log(f"Starting server on ws://{host}:{port}")

    def stop(self) -> None:
        loop = self._loop
        if not loop:
            return

        async def _shutdown() -> None:
            self.log("Stopping server...")
            if self._heartbeat_task:
                self._heartbeat_task.cancel()
            if self._time_sync_task:
                self._time_sync_task.cancel()
            if self._server is not None:
                self._server.close()
                await self._server.wait_closed()
            await self._disconnect_all()

        fut = asyncio.run_coroutine_threadsafe(_shutdown(), loop)
        try:
            fut.result(timeout=5)
        except Exception as exc:
            self.log(f"Shutdown warning: {exc}")

        loop.call_soon_threadsafe(loop.stop)
        self._loop = None
        self._server = None

        with self._lock:
            self._pull_queue.clear()
            self._active_pull = None
            for request in self._preview_requests.values():
                if request.timeout_task:
                    request.timeout_task.cancel()
            self._preview_requests.clear()
            self._preview_current_request_by_device.clear()

        self.event_queue.put(("server_stopped", None))

    def update_timecode_anchor(self, packet: dict[str, Any]) -> None:
        loop = self._loop
        if not loop:
            return

        fps = packet.get("fps")
        hours = packet.get("hours")
        minutes = packet.get("minutes")
        seconds = packet.get("seconds")
        frames = packet.get("frames")
        if not all(isinstance(v, int) for v in (fps, hours, minutes, seconds, frames)):
            return
        if fps <= 0:
            return

        total_frames = ((((hours * 60) + minutes) * 60) + seconds) * fps + frames
        loop.call_soon_threadsafe(self._set_timecode_anchor,
                                  total_frames,
                                  fps,
                                  "tentacle_sync_e")

    def clear_timecode_anchor(self) -> None:
        loop = self._loop
        if not loop:
            return
        loop.call_soon_threadsafe(self._clear_timecode_anchor)

    def configure_time_source(self, source: str, fps: int | None = None) -> None:
        normalized_source = "laptop" if source.strip().lower() == "laptop" else "tentacle"
        normalized_fps = fps if isinstance(fps, int) and fps > 0 else self._laptop_timecode_fps
        normalized_fps = min(max(normalized_fps, 1), 120)

        loop = self._loop
        if not loop:
            self._time_source = normalized_source
            self._laptop_timecode_fps = normalized_fps
            return

        loop.call_soon_threadsafe(self._set_time_source, normalized_source, normalized_fps)

    def send_command_all(self, command: str, payload: dict[str, Any] | None = None) -> None:
        payload = payload or {}
        loop = self._loop
        if not loop:
            self.log("Server not running.")
            return

        request_id = str(uuid.uuid4())
        msg = {
            "type": "command",
            "command": command,
            "request_id": request_id,
            **payload,
        }

        async def _broadcast() -> None:
            with self._lock:
                devices = list(self.devices.values())
            if not devices:
                self.log(f"No devices connected for command: {command}")
                return

            for device in devices:
                device.pending_acks[request_id] = command

            await self._send_to_devices(devices=devices,
                                        encoded=json.dumps(msg),
                                        log_prefix=f"Broadcast '{command}'",
                                        request_id=request_id)

        asyncio.run_coroutine_threadsafe(_broadcast(), loop)

    def send_command_to_device(self,
                               device_id: str,
                               command: str,
                               payload: dict[str, Any] | None = None) -> None:
        payload = payload or {}
        loop = self._loop
        if not loop:
            self.log("Server not running.")
            return

        async def _send() -> None:
            await self._send_command_to_device(device_id=device_id,
                                               command=command,
                                               payload=payload)

        asyncio.run_coroutine_threadsafe(_send(), loop)

    def copy_camera_params(self, device_id: str) -> None:
        loop = self._loop
        if not loop:
            self.log("Server not running.")
            return

        asyncio.run_coroutine_threadsafe(self._copy_camera_params(device_id), loop)

    def sync_camera_params_all(self, dry_run: bool = False) -> None:
        loop = self._loop
        if not loop:
            self.log("Server not running.")
            return

        asyncio.run_coroutine_threadsafe(self._sync_camera_params_all(dry_run=dry_run), loop)

    def queue_pull_videos(self,
                          device_id: str,
                          max_files: int = 0,
                          policy: str = "new_only",
                          upload_url: str | None = None) -> None:
        loop = self._loop
        if not loop:
            self.log("Server not running.")
            return

        payload: dict[str, Any] = {
            "job_id": f"pull-{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}",
            "policy": policy,
        }
        if max_files > 0:
            payload["max_files"] = max_files
        if upload_url:
            payload["upload_url"] = upload_url

        request = PullVideosRequest(device_id=device_id, payload=payload)

        async def _enqueue() -> None:
            with self._lock:
                self._pull_queue.append(request)
                queued_count = len(self._pull_queue)
                active_device = self._active_pull.device_id if self._active_pull else None

            self.log(
                f"Queued pull_videos for {device_id} job={payload['job_id']} "
                f"(queue={queued_count}, active={active_device or 'none'})."
            )
            await self._dispatch_next_pull_if_idle()

        asyncio.run_coroutine_threadsafe(_enqueue(), loop)

    def configure_preview_upload_url(self, upload_url: str) -> None:
        self._preview_upload_url = upload_url.strip()

    def request_preview_photo(self, device_id: str) -> None:
        loop = self._loop
        if not loop:
            self.log("Server not running.")
            return
        if not self._preview_upload_url:
            self.log("Preview photo request failed; upload endpoint is not configured.")
            return

        batch_id = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        asyncio.run_coroutine_threadsafe(
            self._request_preview_photo(device_id=device_id, batch_id=batch_id, attempt=1),
            loop,
        )

    def request_preview_photos_all(self) -> None:
        loop = self._loop
        if not loop:
            self.log("Server not running.")
            return
        if not self._preview_upload_url:
            self.log("Preview photo request failed; upload endpoint is not configured.")
            return

        batch_id = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        asyncio.run_coroutine_threadsafe(
            self._request_preview_photos_all(batch_id=batch_id),
            loop,
        )

    def handle_preview_upload_received(self, payload: dict[str, Any]) -> None:
        loop = self._loop
        if not loop:
            return
        asyncio.run_coroutine_threadsafe(self._handle_preview_upload_received(payload), loop)

    def pull_status(self) -> dict[str, Any]:
        with self._lock:
            active = self._active_pull
            return {
                "active_device_id": active.device_id if active else "",
                "active_job_id": (active.payload.get("job_id", "") if active else ""),
                "queued_count": len(self._pull_queue),
            }

    def snapshot_devices(self) -> list[dict[str, Any]]:
        with self._lock:
            data = [
                {
                    "device_id": d.device_id,
                    "name": d.name,
                    "app_version": d.app_version,
                    "endpoint": d.endpoint,
                    "last_seen_unix": d.last_seen_unix,
                    "recording": d.recording,
                    "armed": d.armed,
                    "battery": d.battery,
                    "storage_gb": d.storage_gb,
                    "local_video_count": d.local_video_count,
                    "uploaded_video_count": d.uploaded_video_count,
                    "pending_upload_video_count": d.pending_upload_video_count,
                    "local_video_bytes": d.local_video_bytes,
                    "uploaded_video_bytes": d.uploaded_video_bytes,
                    "pending_upload_video_bytes": d.pending_upload_video_bytes,
                    "capture_mode": d.capture_mode,
                    "actual_capture_mode": d.actual_capture_mode,
                    "actual_video_width": d.actual_video_width,
                    "actual_video_height": d.actual_video_height,
                    "actual_video_fps": d.actual_video_fps,
                    "supported_capture_modes": list(d.supported_capture_modes),
                    "tentacle_state": d.tentacle_state,
                    "timecode": d.timecode,
                    "fps": d.fps,
                    "rig_state": d.rig_state,
                    "pending_acks": dict(d.pending_acks),
                    "transfer_state": d.transfer_state,
                    "transfer_detail": d.transfer_detail,
                    "transfer_job_id": d.transfer_job_id,
                    "camera_params_summary": d.last_camera_params_summary,
                    "camera_params_status": d.last_camera_params_status,
                    "camera_params_report": d.last_camera_params_report,
                    "preview_state": d.preview_state,
                    "preview_detail": d.preview_detail,
                    "preview_request_id": d.preview_request_id,
                    "preview_batch_id": d.preview_batch_id,
                    "preview_image_path": d.preview_image_path,
                    "preview_metadata_path": d.preview_metadata_path,
                    "preview_updated_unix": d.preview_updated_unix,
                }
                for d in self.devices.values()
            ]
        data.sort(key=lambda x: x["name"])
        return data

    def log(self, message: str) -> None:
        self.event_queue.put(("log", f"[{timestamp_now()}] {message}"))

    def _run_loop(self) -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        self._loop = loop

        async def _startup() -> None:
            self._server = await websockets.serve(self._handle_connection, self._host, self._port)
            self._heartbeat_task = asyncio.create_task(self._heartbeat_monitor())
            self._time_sync_task = asyncio.create_task(self._time_sync_loop())
            self.event_queue.put(("server_started", {"host": self._host, "port": self._port}))

        loop.run_until_complete(_startup())
        try:
            loop.run_forever()
        finally:
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
            loop.close()

    async def _disconnect_all(self) -> None:
        with self._lock:
            websockets_to_close = [d.websocket for d in self.devices.values()]
            self.devices.clear()
            self._pull_queue.clear()
            self._active_pull = None
            for request in self._preview_requests.values():
                if request.timeout_task:
                    request.timeout_task.cancel()
            self._preview_requests.clear()
            self._preview_current_request_by_device.clear()
        for ws in websockets_to_close:
            try:
                await ws.close(code=1001, reason="Director shutdown")
            except Exception:
                pass
        self.event_queue.put(("devices_updated", self.snapshot_devices()))

    def _set_timecode_anchor(self, total_frames: int, fps: int, source: str) -> None:
        self._timecode_anchor_monotonic = time.monotonic()
        self._timecode_anchor_total_frames = total_frames
        self._timecode_anchor_fps = fps
        self._timecode_anchor_source = source

    def _set_time_source(self, source: str, fps: int) -> None:
        self._time_source = source
        self._laptop_timecode_fps = min(max(fps, 1), 120)

    def _clear_timecode_anchor(self) -> None:
        self._timecode_anchor_monotonic = None
        self._timecode_anchor_total_frames = None
        self._timecode_anchor_fps = None
        self._timecode_anchor_source = "tentacle_sync_e"

    async def _heartbeat_monitor(self) -> None:
        while True:
            await asyncio.sleep(self.HEARTBEAT_CHECK_SECONDS)
            # iPhones in armed_idle intentionally send low-rate status updates to save power.
            # Keep this comfortably above the app's 5s idle heartbeat so normal Wi-Fi jitter
            # doesn't look like a disconnected device.
            cutoff = time.time() - self.HEARTBEAT_TIMEOUT_SECONDS
            stale: list[WebSocketServerProtocol] = []
            with self._lock:
                for ws, d in self.devices.items():
                    if d.last_seen_unix < cutoff:
                        stale.append(ws)
            for ws in stale:
                try:
                    await ws.close(code=1001, reason="Heartbeat timeout")
                except Exception:
                    pass

    async def _time_sync_loop(self) -> None:
        while True:
            await asyncio.sleep(0.1)

            with self._lock:
                devices = list(self.devices.values())
            if not devices:
                continue

            message = self._build_time_sync_message()
            encoded = json.dumps(message)
            await asyncio.gather(
                *(device.websocket.send(encoded) for device in devices),
                return_exceptions=True,
            )

    def _build_time_sync_message(self) -> dict[str, Any]:
        unix_ms = int(time.time() * 1000)
        message: dict[str, Any] = {
            "type": "time_sync",
            "unix_ms": unix_ms,
            "seq": self._time_sync_sequence,
        }
        self._time_sync_sequence += 1
        message.update(self._current_timecode_payload(unix_ms=unix_ms))
        return message

    def _current_timecode_payload(self, unix_ms: int) -> dict[str, Any]:
        if self._time_source == "laptop":
            return self._laptop_timecode_payload(unix_ms=unix_ms)

        anchor_monotonic = self._timecode_anchor_monotonic
        anchor_total_frames = self._timecode_anchor_total_frames
        fps = self._timecode_anchor_fps
        if anchor_monotonic is None or anchor_total_frames is None or fps is None or fps <= 0:
            return {}

        elapsed = max(0.0, time.monotonic() - anchor_monotonic)
        advanced_frames = int(elapsed * fps)
        frames_per_day = 24 * 60 * 60 * fps
        total_frames = (anchor_total_frames + advanced_frames) % frames_per_day

        hours = total_frames // (3600 * fps)
        minute_remainder = total_frames % (3600 * fps)
        minutes = minute_remainder // (60 * fps)
        second_remainder = minute_remainder % (60 * fps)
        seconds = second_remainder // fps
        frames = second_remainder % fps

        return {
            "source": self._timecode_anchor_source,
            "fps": fps,
            "hours": hours,
            "minutes": minutes,
            "seconds": seconds,
            "frames": frames,
            "timecode": f"{hours:02d}:{minutes:02d}:{seconds:02d}:{frames:02d}",
            "total_frames_of_day": total_frames,
        }

    def _laptop_timecode_payload(self, unix_ms: int) -> dict[str, Any]:
        fps = min(max(self._laptop_timecode_fps, 1), 120)
        now_local = datetime.fromtimestamp(unix_ms / 1000.0)
        seconds_of_day = (now_local.hour * 3600) + (now_local.minute * 60) + now_local.second
        frames = int((now_local.microsecond / 1_000_000.0) * fps)
        frames = min(frames, fps - 1)
        total_frames = (seconds_of_day * fps) + frames

        return {
            "source": "director_laptop_clock",
            "fps": fps,
            "hours": now_local.hour,
            "minutes": now_local.minute,
            "seconds": now_local.second,
            "frames": frames,
            "timecode": f"{now_local.hour:02d}:{now_local.minute:02d}:{now_local.second:02d}:{frames:02d}",
            "total_frames_of_day": total_frames,
        }

    async def _handle_connection(self, websocket: WebSocketServerProtocol) -> None:
        provisional = DeviceState(
            websocket=websocket,
            device_id=f"unknown-{uuid.uuid4().hex[:8]}",
            name="Unknown",
        )
        with self._lock:
            self.devices[websocket] = provisional
        self.log(f"Client connected from {provisional.endpoint}")
        self.event_queue.put(("devices_updated", self.snapshot_devices()))

        try:
            async for raw in websocket:
                await self._handle_message(websocket, raw)
        except websockets.ConnectionClosed:
            pass
        except Exception as exc:
            self.log(f"Connection error: {exc}")
        finally:
            disconnected: DeviceState | None
            with self._lock:
                disconnected = self.devices.pop(websocket, None)
            if disconnected:
                await self._release_active_pull_if_device(disconnected.device_id,
                                                          reason="device disconnected")
                self._mark_preview_disconnected(disconnected.device_id)
                self.log(f"Client disconnected: {disconnected.name} ({disconnected.device_id})")
            self.event_queue.put(("devices_updated", self.snapshot_devices()))

    async def _handle_message(self, websocket: WebSocketServerProtocol, raw: str) -> None:
        try:
            msg = json.loads(raw)
            if not isinstance(msg, dict):
                raise ValueError("Payload must be JSON object")
        except Exception as exc:
            self.log(f"Invalid JSON from client: {exc}")
            return

        mtype = msg.get("type")
        if not isinstance(mtype, str):
            self.log("Ignoring message with missing type.")
            return

        with self._lock:
            device = self.devices.get(websocket)
        if not device:
            return

        device.last_seen_unix = time.time()

        if mtype == "hello":
            device.device_id = str(msg.get("device_id") or device.device_id)
            device.name = str(msg.get("name") or device.name)
            device.app_version = str(msg.get("app_version") or "")
            self.log(f"HELLO from {device.name} ({device.device_id})")

        elif mtype == "status":
            device.recording = bool(msg.get("recording", device.recording))
            device.armed = bool(msg.get("armed", device.armed))
            device.battery = to_float_or_none(msg.get("battery"))
            device.storage_gb = to_float_or_none(msg.get("storage_gb"))
            if "local_video_count" in msg:
                device.local_video_count = to_int_or_none(msg.get("local_video_count"))
            if "uploaded_video_count" in msg:
                device.uploaded_video_count = to_int_or_none(msg.get("uploaded_video_count"))
            if "pending_upload_video_count" in msg:
                device.pending_upload_video_count = to_int_or_none(msg.get("pending_upload_video_count"))
            if "local_video_bytes" in msg:
                device.local_video_bytes = to_int_or_none(msg.get("local_video_bytes"))
            if "uploaded_video_bytes" in msg:
                device.uploaded_video_bytes = to_int_or_none(msg.get("uploaded_video_bytes"))
            if "pending_upload_video_bytes" in msg:
                device.pending_upload_video_bytes = to_int_or_none(msg.get("pending_upload_video_bytes"))
            if "capture_mode" in msg:
                device.capture_mode = str(msg.get("capture_mode") or "")
            if "actual_capture_mode" in msg:
                device.actual_capture_mode = str(msg.get("actual_capture_mode") or "")
            if "actual_video_width" in msg:
                device.actual_video_width = to_int_or_none(msg.get("actual_video_width"))
            if "actual_video_height" in msg:
                device.actual_video_height = to_int_or_none(msg.get("actual_video_height"))
            if "actual_video_fps" in msg:
                device.actual_video_fps = to_float_or_none(msg.get("actual_video_fps"))
            if "supported_capture_modes" in msg and isinstance(msg.get("supported_capture_modes"), list):
                device.supported_capture_modes = [str(value) for value in msg.get("supported_capture_modes") if value]
            if "tentacle_state" in msg:
                device.tentacle_state = str(msg.get("tentacle_state") or "unknown")
            if "timecode" in msg:
                device.timecode = str(msg.get("timecode") or "")
            fps = msg.get("fps")
            device.fps = int(fps) if isinstance(fps, int) else device.fps
            if "camera_params_status" in msg:
                device.last_camera_params_status = str(msg.get("camera_params_status") or "")
            if "camera_params_summary" in msg:
                device.last_camera_params_summary = str(msg.get("camera_params_summary") or "")
            if "rig_state" in msg:
                device.rig_state = str(msg.get("rig_state") or "")

        elif mtype == "ack":
            request_id = str(msg.get("request_id") or "")
            ok = bool(msg.get("ok", False))
            detail = str(msg.get("detail") or "")
            command = device.pending_acks.pop(request_id, "unknown")
            device.pending_camera_param_requests.pop(request_id, None)
            payload = msg.get("payload")
            if command in {"export_camera_params", "apply_camera_params", "validate_camera_params"}:
                if isinstance(payload, dict):
                    camera_payload = self._camera_params_payload(payload)
                    device.last_camera_params_report = camera_payload or payload
                    device.last_camera_params_summary = self._camera_params_summary(camera_payload)
                    report = camera_payload.get("apply_report") or camera_payload.get("validation_report")
                    if isinstance(report, dict):
                        device.last_camera_params_status = str(report.get("classification") or "")
                elif not ok:
                    device.last_camera_params_status = "failed"
            if isinstance(payload, dict) and "current_state" in payload:
                device.rig_state = str(payload.get("current_state") or "")
            if isinstance(payload, dict):
                if "battery" in payload:
                    device.battery = to_float_or_none(payload.get("battery"))
                if "storage_gb" in payload:
                    device.storage_gb = to_float_or_none(payload.get("storage_gb"))
                if "local_video_count" in payload:
                    device.local_video_count = to_int_or_none(payload.get("local_video_count"))
                if "uploaded_video_count" in payload:
                    device.uploaded_video_count = to_int_or_none(payload.get("uploaded_video_count"))
                if "pending_upload_video_count" in payload:
                    device.pending_upload_video_count = to_int_or_none(payload.get("pending_upload_video_count"))
                if "local_video_bytes" in payload:
                    device.local_video_bytes = to_int_or_none(payload.get("local_video_bytes"))
                if "uploaded_video_bytes" in payload:
                    device.uploaded_video_bytes = to_int_or_none(payload.get("uploaded_video_bytes"))
                if "pending_upload_video_bytes" in payload:
                    device.pending_upload_video_bytes = to_int_or_none(payload.get("pending_upload_video_bytes"))
                if "capture_mode" in payload:
                    device.capture_mode = str(payload.get("capture_mode") or "")
                if "actual_capture_mode" in payload:
                    device.actual_capture_mode = str(payload.get("actual_capture_mode") or "")
                if "actual_video_width" in payload:
                    device.actual_video_width = to_int_or_none(payload.get("actual_video_width"))
                if "actual_video_height" in payload:
                    device.actual_video_height = to_int_or_none(payload.get("actual_video_height"))
                if "actual_video_fps" in payload:
                    device.actual_video_fps = to_float_or_none(payload.get("actual_video_fps"))
                if "supported_capture_modes" in payload and isinstance(payload.get("supported_capture_modes"), list):
                    device.supported_capture_modes = [str(value) for value in payload.get("supported_capture_modes") if value]
            waiter = self._ack_waiters.pop((device.device_id, request_id), None)
            if waiter and not waiter.done():
                waiter.set_result(msg)
            result = "OK" if ok else "FAIL"
            self.log(
                f"ACK {result} from {device.name} ({device.device_id}) "
                f"command={command} req={request_id} detail={detail}"
            )
            if command == "pull_videos" and not ok:
                await self._release_active_pull_if_device(device.device_id,
                                                          reason=f"pull_videos ack failed: {detail}")

        elif mtype == "pong":
            request_id = str(msg.get("request_id") or "")
            device.pending_acks.pop(request_id, None)

        elif mtype == "transfer":
            state = str(msg.get("state") or "")
            detail = str(msg.get("detail") or "")
            job_id = str(msg.get("job_id") or "")
            sent_files = msg.get("sent_files")
            total_files = msg.get("total_files")

            if not detail and isinstance(sent_files, int) and isinstance(total_files, int):
                detail = f"{sent_files}/{total_files} files"

            device.transfer_state = state
            device.transfer_detail = detail
            device.transfer_job_id = job_id
            device.transfer_updated_unix = time.time()

            self.log(
                f"TRANSFER {state} from {device.name} ({device.device_id}) "
                f"job={job_id} detail={detail}"
            )

            if state in {"done", "failed", "cancelled"}:
                await self._release_active_pull_if_device(device.device_id,
                                                          reason=f"transfer {state}")

        elif mtype == "preview_photo":
            request_id = str(msg.get("request_id") or "")
            state = str(msg.get("state") or "")
            detail = str(msg.get("detail") or "")
            failure_reason = str(msg.get("failure_reason") or "")
            await self._handle_preview_status_message(device=device,
                                                      request_id=request_id,
                                                      state=state,
                                                      detail=detail,
                                                      failure_reason=failure_reason)

        else:
            self.log(f"Unhandled message type '{mtype}' from {device.name}")

        self.event_queue.put(("devices_updated", self.snapshot_devices()))

    async def _send_to_devices(self,
                               devices: list[DeviceState],
                               encoded: str,
                               log_prefix: str,
                               request_id: str) -> None:
        results = await asyncio.gather(
            *(device.websocket.send(encoded) for device in devices),
            return_exceptions=True,
        )

        failures = 0
        for device, result in zip(devices, results):
            if isinstance(result, Exception):
                failures += 1
                self.log(f"Send failed to {device.name} ({device.device_id}): {result}")
        ok_count = len(devices) - failures
        self.log(f"{log_prefix} request_id={request_id} sent to {ok_count}/{len(devices)} devices.")

    async def _send_command_to_device(self,
                                      device_id: str,
                                      command: str,
                                      payload: dict[str, Any]) -> bool:
        with self._lock:
            target = next((d for d in self.devices.values() if d.device_id == device_id), None)

        if not target:
            self.log(f"Device not connected for command '{command}': {device_id}")
            return False

        request_id = str(uuid.uuid4())
        target.pending_acks[request_id] = command
        msg = {
            "type": "command",
            "command": command,
            "request_id": request_id,
            **payload,
        }

        try:
            await target.websocket.send(json.dumps(msg))
        except Exception as exc:
            target.pending_acks.pop(request_id, None)
            self.log(f"Send failed to {target.name} ({target.device_id}): {exc}")
            return False

        self.log(
            f"Unicast '{command}' request_id={request_id} sent to "
            f"{target.name} ({target.device_id})."
        )
        return True

    async def _send_command_wait_ack(self,
                                     device: DeviceState,
                                     command: str,
                                     payload: dict[str, Any] | None = None,
                                     timeout: float = 15.0,
                                     request_id: str | None = None) -> dict[str, Any]:
        payload = payload or {}
        request_id = request_id or str(uuid.uuid4())
        future: asyncio.Future = asyncio.get_running_loop().create_future()
        self._ack_waiters[(device.device_id, request_id)] = future
        device.pending_acks[request_id] = command
        if command in {"export_camera_params", "apply_camera_params", "validate_camera_params"}:
            device.pending_camera_param_requests[request_id] = command

        msg = {
            "type": "command",
            "command": command,
            "request_id": request_id,
            **payload,
        }

        try:
            await device.websocket.send(json.dumps(msg))
        except Exception:
            self._ack_waiters.pop((device.device_id, request_id), None)
            device.pending_acks.pop(request_id, None)
            device.pending_camera_param_requests.pop(request_id, None)
            raise

        try:
            return await asyncio.wait_for(future, timeout=timeout)
        except Exception:
            self._ack_waiters.pop((device.device_id, request_id), None)
            device.pending_acks.pop(request_id, None)
            device.pending_camera_param_requests.pop(request_id, None)
            raise

    async def _request_preview_photos_all(self, batch_id: str) -> None:
        with self._lock:
            devices = list(self.devices.values())
        if not devices:
            self.log("No devices connected for preview photo request.")
            return

        self.log(f"Requesting preview photos from {len(devices)} device(s), batch={batch_id}.")
        for index in range(0, len(devices), self._preview_batch_size):
            batch = devices[index:index + self._preview_batch_size]
            await asyncio.gather(
                *(self._request_preview_photo(device.device_id, batch_id=batch_id, attempt=1) for device in batch),
                return_exceptions=True,
            )
            if index + self._preview_batch_size < len(devices):
                await asyncio.sleep(0.4)

    async def _request_preview_photo(self, device_id: str, batch_id: str, attempt: int) -> None:
        with self._lock:
            device = next((d for d in self.devices.values() if d.device_id == device_id), None)
        if not device:
            self.log(f"Preview photo request failed; device not connected: {device_id}")
            return

        request_id = str(uuid.uuid4())
        request = PreviewPhotoRequest(device_id=device_id,
                                      request_id=request_id,
                                      batch_id=batch_id,
                                      attempt=attempt,
                                      started_unix=time.time())
        self._store_preview_request(request, state="requested", detail=f"Attempt {attempt}.")

        payload = {
            "batch_id": batch_id,
            "upload_url": self._preview_upload_url,
            "long_edge": 1280,
            "jpeg_quality": 0.65,
            "upload_jitter_seconds": 3.0,
            "attempt": attempt,
        }

        try:
            ack = await self._send_command_wait_ack(device,
                                                    "capture_preview_photo",
                                                    payload=payload,
                                                    timeout=8.0,
                                                    request_id=request_id)
        except Exception as exc:
            await self._retry_or_fail_preview_request(request,
                                                      status="timeout",
                                                      detail=f"Preview command ACK timed out/failed: {exc}",
                                                      retryable=True)
            return

        if not bool(ack.get("ok")):
            payload_status = ""
            ack_payload = ack.get("payload")
            if isinstance(ack_payload, dict):
                payload_status = str(ack_payload.get("status") or "")
            status = payload_status if payload_status else "capture_failed"
            await self._finish_preview_request(request,
                                               status=status,
                                               detail=str(ack.get("detail") or "Preview capture was rejected."),
                                               retryable=False)
            return

        self._update_preview_device(device_id=device_id,
                                    request_id=request_id,
                                    batch_id=batch_id,
                                    state="accepted",
                                    detail="Capture accepted; waiting for upload.")
        timeout_task = asyncio.create_task(self._preview_timeout_after(device_id=device_id,
                                                                       request_id=request_id))
        with self._lock:
            current = self._preview_requests.get((device_id, request_id))
            if current:
                current.timeout_task = timeout_task

    def _store_preview_request(self,
                               request: PreviewPhotoRequest,
                               state: str,
                               detail: str) -> None:
        with self._lock:
            previous_request_id = self._preview_current_request_by_device.get(request.device_id)
            if previous_request_id:
                previous = self._preview_requests.pop((request.device_id, previous_request_id), None)
                if previous and previous.timeout_task:
                    previous.timeout_task.cancel()
            self._preview_requests[(request.device_id, request.request_id)] = request
            self._preview_current_request_by_device[request.device_id] = request.request_id
        self._update_preview_device(device_id=request.device_id,
                                    request_id=request.request_id,
                                    batch_id=request.batch_id,
                                    state=state,
                                    detail=detail)

    async def _handle_preview_status_message(self,
                                             device: DeviceState,
                                             request_id: str,
                                             state: str,
                                             detail: str,
                                             failure_reason: str) -> None:
        if not request_id:
            return
        normalized_state = state or "unknown"
        with self._lock:
            current_request_id = self._preview_current_request_by_device.get(device.device_id)
            current_state = device.preview_state
        if current_request_id and current_request_id != request_id:
            return
        if normalized_state == "done" and not current_request_id and current_state == "success":
            return
        if normalized_state == "failed":
            request = self._preview_request(device.device_id, request_id)
            retryable = failure_reason == "upload_failed"
            await self._retry_or_fail_preview_request(
                request or PreviewPhotoRequest(device_id=device.device_id,
                                               request_id=request_id,
                                               batch_id=device.preview_batch_id or "unknown-batch",
                                               attempt=1,
                                               started_unix=time.time()),
                status=failure_reason or "capture_failed",
                detail=detail or "Preview photo failed.",
                retryable=retryable,
            )
            return

        if normalized_state in {"capturing", "uploading", "done"}:
            self._update_preview_device(device_id=device.device_id,
                                        request_id=request_id,
                                        batch_id=device.preview_batch_id,
                                        state=normalized_state,
                                        detail=detail)

    async def _handle_preview_upload_received(self, payload: dict[str, Any]) -> None:
        device_id = str(payload.get("device_id") or "")
        request_id = str(payload.get("request_id") or "")
        batch_id = str(payload.get("batch_id") or "")
        kind = str(payload.get("kind") or "")
        path = str(payload.get("path") or "")
        if not device_id or not request_id or not path:
            return

        with self._lock:
            current_request_id = self._preview_current_request_by_device.get(device_id)
            request = self._preview_requests.get((device_id, request_id))
            if current_request_id and current_request_id != request_id:
                self.log(
                    f"Ignoring late preview upload from {device_id} req={request_id}; "
                    f"current req={current_request_id}."
                )
                return
            device = next((d for d in self.devices.values() if d.device_id == device_id), None)
            if not device:
                self.log(f"Preview upload received for disconnected device {device_id}: {path}")
                return

            if request is None:
                request = PreviewPhotoRequest(device_id=device_id,
                                              request_id=request_id,
                                              batch_id=batch_id,
                                              attempt=1,
                                              started_unix=time.time())
                self._preview_requests[(device_id, request_id)] = request
                self._preview_current_request_by_device[device_id] = request_id

            if kind == "preview_photo":
                request.image_path = path
                device.preview_image_path = path
            elif kind == "preview_photo_metadata":
                request.metadata_path = path
                device.preview_metadata_path = path

            device.preview_state = "receiving"
            device.preview_detail = "Received preview upload."
            device.preview_request_id = request_id
            device.preview_batch_id = request.batch_id or batch_id
            device.preview_updated_unix = time.time()

            completed = bool(request.image_path and request.metadata_path)
            if completed:
                if request.timeout_task:
                    request.timeout_task.cancel()
                device.preview_state = "success"
                device.preview_detail = "Preview photo received."
                self._preview_requests.pop((device_id, request_id), None)
                if self._preview_current_request_by_device.get(device_id) == request_id:
                    self._preview_current_request_by_device.pop(device_id, None)

        self.log(f"Preview upload {kind} from {device_id} req={request_id}: {path}")
        self.event_queue.put(("devices_updated", self.snapshot_devices()))

    async def _preview_timeout_after(self, device_id: str, request_id: str) -> None:
        await asyncio.sleep(self._preview_timeout_seconds)
        request = self._preview_request(device_id, request_id)
        if not request:
            return
        await self._retry_or_fail_preview_request(request,
                                                  status="timeout",
                                                  detail="Timed out waiting for preview image and metadata uploads.",
                                                  retryable=True)

    async def _retry_or_fail_preview_request(self,
                                             request: PreviewPhotoRequest,
                                             status: str,
                                             detail: str,
                                             retryable: bool) -> None:
        if retryable and request.attempt <= self._preview_max_retries:
            self._cleanup_preview_request(request)
            self._update_preview_device(device_id=request.device_id,
                                        request_id=request.request_id,
                                        batch_id=request.batch_id,
                                        state="retrying",
                                        detail=f"{detail} Retrying once.")
            self.log(
                f"Retrying preview photo for {request.device_id} batch={request.batch_id} "
                f"after {status}."
            )
            await self._request_preview_photo(device_id=request.device_id,
                                              batch_id=request.batch_id,
                                              attempt=request.attempt + 1)
            return

        await self._finish_preview_request(request,
                                           status=status,
                                           detail=detail,
                                           retryable=False)

    async def _finish_preview_request(self,
                                      request: PreviewPhotoRequest,
                                      status: str,
                                      detail: str,
                                      retryable: bool) -> None:
        _ = retryable
        self._cleanup_preview_request(request)
        self._update_preview_device(device_id=request.device_id,
                                    request_id=request.request_id,
                                    batch_id=request.batch_id,
                                    state=status,
                                    detail=detail)
        self.log(
            f"Preview photo {status} for {request.device_id} "
            f"req={request.request_id}: {detail}"
        )

    def _preview_request(self, device_id: str, request_id: str) -> PreviewPhotoRequest | None:
        with self._lock:
            return self._preview_requests.get((device_id, request_id))

    def _cleanup_preview_request(self, request: PreviewPhotoRequest) -> None:
        with self._lock:
            current = self._preview_requests.pop((request.device_id, request.request_id), None)
            current_task = asyncio.current_task()
            if current and current.timeout_task and current.timeout_task is not current_task:
                current.timeout_task.cancel()
            if self._preview_current_request_by_device.get(request.device_id) == request.request_id:
                self._preview_current_request_by_device.pop(request.device_id, None)

    def _mark_preview_disconnected(self, device_id: str) -> None:
        with self._lock:
            request_id = self._preview_current_request_by_device.pop(device_id, "")
            request = self._preview_requests.pop((device_id, request_id), None) if request_id else None
            if request and request.timeout_task:
                request.timeout_task.cancel()
        if request_id:
            self.log(f"Preview photo disconnected for {device_id} req={request_id}.")

    def _update_preview_device(self,
                               device_id: str,
                               request_id: str,
                               batch_id: str,
                               state: str,
                               detail: str) -> None:
        with self._lock:
            device = next((d for d in self.devices.values() if d.device_id == device_id), None)
            if not device:
                return
            device.preview_state = state
            device.preview_detail = detail
            device.preview_request_id = request_id
            device.preview_batch_id = batch_id
            device.preview_updated_unix = time.time()
        self.event_queue.put(("devices_updated", self.snapshot_devices()))

    async def _copy_camera_params(self, device_id: str) -> None:
        with self._lock:
            device = next((d for d in self.devices.values() if d.device_id == device_id), None)
        if not device:
            self.log(f"Copy camera params failed; device not connected: {device_id}")
            return

        try:
            ack = await self._send_command_wait_ack(device,
                                                    "export_camera_params",
                                                    timeout=20.0)
        except Exception as exc:
            self.log(f"Copy camera params timed out/failed for {device.name}: {exc}")
            return

        if not bool(ack.get("ok")):
            self.log(f"Copy camera params rejected by {device.name}: {ack.get('detail')}")
            return

        payload = self._camera_params_payload(ack.get("payload"))
        if not self._valid_export_payload(payload):
            self.log(f"Copy camera params failed for {device.name}: invalid payload schema.")
            return

        self._preset_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
        safe_name = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in device.name)[:40] or "device"
        path = self._preset_dir / f"{timestamp}-{safe_name}-{device.device_id}.json"
        path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

        self._camera_param_preset = payload
        self._camera_param_preset_path = path
        device.last_camera_params_report = payload
        device.last_camera_params_status = "copied"
        device.last_camera_params_summary = self._camera_params_summary(payload)
        self.log(f"Copied camera params from {device.name}; preset saved to {path}.")
        self.event_queue.put(("camera_params_status", f"Camera params: preset from {device.name}"))
        self.event_queue.put(("devices_updated", self.snapshot_devices()))

    async def _sync_camera_params_all(self, dry_run: bool = False) -> None:
        preset = self._camera_param_preset
        if not preset:
            self.log("No camera params preset loaded. Use Copy Params Selected first.")
            return
        requested_profile = preset.get("requested_profile")
        if not isinstance(requested_profile, dict):
            self.log("Camera params preset is missing requested_profile.")
            return

        with self._lock:
            devices = list(self.devices.values())
        if not devices:
            self.log("No devices connected for camera params sync.")
            return

        started = datetime.utcnow()
        request_payload = {"preset": requested_profile, "dry_run": dry_run}
        self.log(f"{'Dry run' if dry_run else 'Sync'} camera params to {len(devices)} device(s).")

        tasks = [
            self._sync_camera_params_one(device, request_payload, dry_run=dry_run)
            for device in devices
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        per_device: list[dict[str, Any]] = []
        for device, result in zip(devices, results):
            if isinstance(result, Exception):
                classification = "incompatible"
                payload: dict[str, Any] = {
                    "device_id": device.device_id,
                    "name": device.name,
                    "classification": classification,
                    "detail": f"Timed out or failed: {result}",
                }
            else:
                payload = result
                classification = str(payload.get("classification") or "incompatible")
            device.last_camera_params_status = classification
            device.last_camera_params_report = payload
            device.last_camera_params_summary = self._camera_params_summary(payload)
            per_device.append(payload)

        report = {
            "schema_version": 1,
            "started_at_utc": started.isoformat(timespec="milliseconds") + "Z",
            "completed_at_utc": datetime.utcnow().isoformat(timespec="milliseconds") + "Z",
            "dry_run": dry_run,
            "source_snapshot_hash": preset.get("source_snapshot_hash"),
            "source_profile_id": requested_profile.get("profileID") or requested_profile.get("profile_id"),
            "preset_path": str(self._camera_param_preset_path or ""),
            "devices": per_device,
        }

        self._sync_report_dir.mkdir(parents=True, exist_ok=True)
        report_path = self._sync_report_dir / f"sync-{started.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}.json"
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
        self.log(f"Camera params {'dry run' if dry_run else 'sync'} report saved to {report_path}.")
        self.event_queue.put(("camera_params_status", f"Camera params: {'dry run' if dry_run else 'sync'} report {report_path}"))
        self.event_queue.put(("devices_updated", self.snapshot_devices()))

    async def _sync_camera_params_one(self,
                                      device: DeviceState,
                                      payload: dict[str, Any],
                                      dry_run: bool) -> dict[str, Any]:
        ack = await self._send_command_wait_ack(device,
                                                "apply_camera_params",
                                                payload=payload,
                                                timeout=30.0)
        raw_ack_payload = ack.get("payload") if isinstance(ack.get("payload"), dict) else {}
        ack_payload = self._camera_params_payload(raw_ack_payload) or raw_ack_payload
        apply_report = ack_payload.get("apply_report") if isinstance(ack_payload, dict) else None
        classification = "incompatible"
        if isinstance(apply_report, dict):
            classification = str(apply_report.get("classification") or classification)
        elif bool(ack.get("ok")):
            classification = "exact_match"

        return {
            "device_id": device.device_id,
            "name": device.name,
            "ok": bool(ack.get("ok")),
            "dry_run": dry_run,
            "classification": classification,
            "detail": str(ack.get("detail") or ""),
            "ack_payload": ack_payload,
        }

    def _camera_params_payload(self, payload: Any) -> dict[str, Any]:
        if not isinstance(payload, dict):
            return {}
        camera_payload = payload.get("camera_params")
        if isinstance(camera_payload, dict):
            return camera_payload
        return payload

    def _valid_export_payload(self, payload: Any) -> bool:
        return (
            isinstance(payload, dict)
            and isinstance(payload.get("requested_profile"), dict)
            and isinstance(payload.get("actual_snapshot"), dict)
        )

    def _camera_params_summary(self, payload: dict[str, Any]) -> str:
        candidate = payload.get("actual_snapshot")
        if not isinstance(candidate, dict):
            ack_payload = payload.get("ack_payload")
            if isinstance(ack_payload, dict):
                candidate = ack_payload.get("actual_snapshot")
        if not isinstance(candidate, dict):
            return ""

        active_format = candidate.get("activeFormat") or candidate.get("active_format")
        fmt = ""
        if isinstance(active_format, dict):
            width = active_format.get("width")
            height = active_format.get("height")
            if width and height:
                fmt = f"{width}x{height}"
        mode = str(candidate.get("actualCaptureModePreset") or candidate.get("actual_capture_mode_preset") or "")
        exposure = candidate.get("exposure")
        iso = ""
        if isinstance(exposure, dict) and isinstance(exposure.get("iso"), (int, float)):
            iso = f"ISO {exposure['iso']:.0f}"
        status = str(payload.get("classification") or payload.get("camera_params_status") or "")
        return ", ".join(part for part in (status, mode, fmt, iso) if part)

    async def _dispatch_next_pull_if_idle(self) -> None:
        while True:
            with self._lock:
                if self._active_pull is not None or not self._pull_queue:
                    return
                request = self._pull_queue.popleft()
                self._active_pull = request

            sent = await self._send_command_to_device(device_id=request.device_id,
                                                      command="pull_videos",
                                                      payload=request.payload)
            if sent:
                return

            self.log(
                f"Dropping queued pull request for {request.device_id}; unable to send command."
            )
            with self._lock:
                if self._active_pull and self._active_pull.payload.get("job_id") == request.payload.get("job_id"):
                    self._active_pull = None

    async def _release_active_pull_if_device(self, device_id: str, reason: str) -> None:
        with self._lock:
            active = self._active_pull
            if active is None or active.device_id != device_id:
                return
            job_id = str(active.payload.get("job_id") or "")
            self._active_pull = None

        self.log(f"Pull job complete for {device_id} job={job_id} ({reason}).")
        await self._dispatch_next_pull_if_idle()
