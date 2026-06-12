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
    role: str = "camera"
    app_version: str = ""
    app_build: str = ""
    last_seen_unix: float = field(default_factory=time.time)
    recording: bool = False
    armed: bool = False
    battery: float | None = None
    storage_gb: float | None = None
    local_video_count: int | None = None
    uploaded_video_count: int | None = None
    pending_upload_video_count: int | None = None
    local_video_bytes: int | None = None
    uploaded_video_bytes: int | None = None
    pending_upload_video_bytes: int | None = None
    capture_mode: str = ""
    actual_capture_mode: str = ""
    actual_video_width: int | None = None
    actual_video_height: int | None = None
    actual_video_fps: float | None = None
    supported_capture_modes: list[str] = field(default_factory=list)
    tentacle_state: str = "unknown"
    timecode: str = ""
    fps: int | None = None
    rig_state: str = ""
    guided_access_enabled: bool = False
    idle_timer_disabled: bool = False
    awake_policy: str = ""
    allow_auto_lock_once: bool = False
    transfer_keep_awake: bool = False
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
    remote_director_state: str = ""
    remote_director_detail: str = ""
    remote_director_requested_unix: float | None = None

    @property
    def endpoint(self) -> str:
        addr = self.websocket.remote_address
        if not addr:
            return "?"
        if isinstance(addr, tuple) and len(addr) >= 2:
            return f"{addr[0]}:{addr[1]}"
        return str(addr)

    @property
    def app_display_version(self) -> str:
        version = self.app_version.strip()
        build = self.app_build.strip()
        if version and build:
            return version if version == build else f"{version} ({build})"
        if version:
            return version
        if build:
            return f"build {build}"
        return ""


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


def to_int_or_none(value: Any) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return max(0, value)
    if isinstance(value, float):
        return max(0, int(value))
    return None


def to_bool_or_none(value: Any) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "yes", "1", "on"}:
            return True
        if normalized in {"false", "no", "0", "off"}:
            return False
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
