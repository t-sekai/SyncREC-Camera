from __future__ import annotations

import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


@dataclass
class DeviceState:
    websocket: Any
    device_id: str
    name: str
    app_version: str = ""
    last_seen_unix: float = field(default_factory=time.time)
    recording: bool = False
    armed: bool = False
    battery: float | None = None
    storage_gb: float | None = None
    tentacle_state: str = "unknown"
    timecode: str = ""
    fps: int | None = None
    pending_acks: dict[str, str] = field(default_factory=dict)
    transfer_state: str = ""
    transfer_job_id: str = ""
    transfer_detail: str = ""
    transfer_updated_unix: float | None = None
    last_camera_params_summary: str = ""
    last_camera_params_status: str = ""
    last_camera_params_report: dict[str, Any] | None = None
    pending_camera_param_requests: dict[str, str] = field(default_factory=dict)
    preview_state: str = ""
    preview_detail: str = ""
    preview_request_id: str = ""
    preview_batch_id: str = ""
    preview_image_path: str = ""
    preview_metadata_path: str = ""
    preview_updated_unix: float | None = None

    @property
    def endpoint(self) -> str:
        addr = self.websocket.remote_address
        if not addr:
            return "?"
        if isinstance(addr, tuple) and len(addr) >= 2:
            return f"{addr[0]}:{addr[1]}"
        return str(addr)


def parse_delay(value: str, fallback: float) -> float:
    try:
        parsed = float(value)
        return max(0.1, parsed)
    except Exception:
        return fallback


def parse_nonnegative_int(value: str, fallback: int) -> int:
    try:
        parsed = int(value)
        return max(0, parsed)
    except Exception:
        return fallback


def yes_no(flag: bool) -> str:
    return "yes" if flag else "no"


def timestamp_now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def to_float_or_none(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def timecode_text(tc: str, fps: int | None) -> str:
    if not tc:
        return ""
    if fps is None:
        return tc
    return f"{tc} @ {fps}"


def timecode_from_total_frames(total_frames: int, fps: int) -> str:
    if fps <= 0:
        return "--:--:--:--"
    frames_per_day = 24 * 60 * 60 * fps
    safe_total = total_frames % frames_per_day

    hours = safe_total // (60 * 60 * fps)
    remainder = safe_total % (60 * 60 * fps)
    minutes = remainder // (60 * fps)
    remainder = remainder % (60 * fps)
    seconds = remainder // fps
    frames = remainder % fps
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}:{frames:02d}"
