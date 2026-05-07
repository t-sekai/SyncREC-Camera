from __future__ import annotations

import json
import queue
import socket
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from .models import timestamp_now


def _safe_component(value: str, fallback: str) -> str:
    trimmed = (value or "").strip()
    if not trimmed:
        return fallback

    cleaned = "".join(ch if (ch.isalnum() or ch in {"-", "_", "."}) else "_" for ch in trimmed)
    cleaned = cleaned.strip("._")
    return cleaned[:80] if cleaned else fallback


def _safe_filename(value: str) -> str:
    return _safe_component(Path(value).name, fallback="upload.bin")


def _first_value(values: dict[str, list[str]], key: str, default: str = "") -> str:
    raw = values.get(key)
    if not raw:
        return default
    return str(raw[0]) if raw[0] is not None else default


def discover_advertised_host(bind_host: str) -> str:
    host = (bind_host or "").strip()
    if host and host not in {"0.0.0.0", "::", "[::]", "localhost"}:
        return host

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            ip = sock.getsockname()[0]
            if ip:
                return ip
    except Exception:
        pass

    try:
        return socket.gethostbyname(socket.gethostname())
    except Exception:
        return "127.0.0.1"


def _format_host_for_url(host: str) -> str:
    if ":" in host and not host.startswith("["):
        return f"[{host}]"
    return host


class UploadIngestServer:
    def __init__(self,
                 event_queue: queue.Queue[tuple[str, Any]],
                 ingest_root: str = "ingest",
                 preview_root: str = "director_app/captures/preview_photos"):
        self.event_queue = event_queue
        self.ingest_root = Path(ingest_root)
        self.preview_root = Path(preview_root)
        self._bind_host = "0.0.0.0"
        self._port = 0
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def is_running(self) -> bool:
        return self._server is not None and self._thread is not None and self._thread.is_alive()

    def start(self, bind_host: str, port: int) -> bool:
        if self.is_running:
            self.log("Upload server already running.")
            return True

        self.ingest_root.mkdir(parents=True, exist_ok=True)
        self._bind_host = bind_host
        self._port = port

        handler_class = self._build_handler_class()

        try:
            self._server = ThreadingHTTPServer((bind_host, port), handler_class)
        except Exception as exc:
            self._server = None
            self.log(f"Failed to start upload server on http://{bind_host}:{port}/upload: {exc}")
            return False

        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        self.log(f"Upload server listening on http://{bind_host}:{port}/upload")
        return True

    def stop(self) -> None:
        server = self._server
        thread = self._thread
        if not server:
            return

        try:
            server.shutdown()
            server.server_close()
        except Exception as exc:
            self.log(f"Upload server shutdown warning: {exc}")

        if thread is not None:
            thread.join(timeout=2)

        self._server = None
        self._thread = None
        self.log("Upload server stopped.")

    def upload_url_for_clients(self, advertised_host: str | None = None) -> str:
        host = advertised_host or discover_advertised_host(self._bind_host)
        return f"http://{_format_host_for_url(host)}:{self._port}/upload"

    def log(self, message: str) -> None:
        self.event_queue.put(("log", f"[{timestamp_now()}] {message}"))

    def _serve(self) -> None:
        server = self._server
        if not server:
            return
        try:
            server.serve_forever(poll_interval=0.5)
        except Exception as exc:
            self.log(f"Upload server error: {exc}")

    def _build_handler_class(self) -> type[BaseHTTPRequestHandler]:
        parent = self

        class UploadHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self) -> None:  # noqa: N802
                parent._handle_post(self)

            def do_GET(self) -> None:  # noqa: N802
                parsed = urlparse(self.path)
                if parsed.path == "/upload/health":
                    parent._write_json(self, 200, {"ok": True})
                    return
                parent._write_json(self, 404, {"ok": False, "error": "Not found."})

            def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
                # Suppress default stderr logging; we emit explicit structured logs.
                return

        return UploadHandler

    def _handle_post(self, handler: BaseHTTPRequestHandler) -> None:
        parsed = urlparse(handler.path)
        if parsed.path not in {"/upload", "/upload/"}:
            self._write_json(handler, 404, {"ok": False, "error": "Not found."})
            return

        query = parse_qs(parsed.query, keep_blank_values=True)

        device_id = _safe_component(
            _first_value(query, "device_id", handler.headers.get("X-Device-ID", "")),
            fallback="unknown-device",
        )
        device_name = _safe_component(
            _first_value(query, "device_name", handler.headers.get("X-Device-Name", "")),
            fallback="unknown-name",
        )
        job_id = _safe_component(
            _first_value(query, "job_id", handler.headers.get("X-Transfer-Job-ID", "")),
            fallback="unknown-job",
        )
        request_id = _safe_component(
            _first_value(query, "request_id", handler.headers.get("X-Request-ID", "")),
            fallback=job_id,
        )
        batch_id = _safe_component(
            _first_value(query, "batch_id", handler.headers.get("X-Preview-Batch-ID", "")),
            fallback=datetime.utcnow().strftime("%Y%m%d_%H%M%S"),
        )
        kind = _safe_component(
            _first_value(query, "kind", handler.headers.get("X-Content-Kind", "")),
            fallback="file",
        )

        filename_query = _first_value(query, "filename", "")
        filename_header = handler.headers.get("X-Original-Filename", "")
        filename = _safe_filename(filename_query or filename_header or "upload.bin")

        content_length_header = handler.headers.get("Content-Length")
        try:
            content_length = int(content_length_header) if content_length_header is not None else -1
        except ValueError:
            self._write_json(handler, 400, {"ok": False, "error": "Invalid Content-Length."})
            return

        if content_length <= 0:
            self._write_json(handler, 411, {"ok": False, "error": "Content-Length required."})
            return

        is_preview_upload = kind in {"preview_photo", "preview_photo_metadata"}
        if is_preview_upload:
            target_dir = self.preview_root / batch_id
            target_dir.mkdir(parents=True, exist_ok=True)
            destination = self._preview_destination(target_dir=target_dir,
                                                    kind=kind,
                                                    device_id=device_id,
                                                    device_name=device_name,
                                                    fallback_filename=filename)
        else:
            target_dir = self.ingest_root / f"{device_name}_{device_id}" / job_id / kind
            target_dir.mkdir(parents=True, exist_ok=True)
            destination = self._unique_destination(target_dir / filename)
        temp_path = destination.with_suffix(destination.suffix + ".part")

        try:
            remaining = content_length
            written = 0
            with temp_path.open("wb") as output:
                while remaining > 0:
                    chunk = handler.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    output.write(chunk)
                    read_bytes = len(chunk)
                    written += read_bytes
                    remaining -= read_bytes

            if written != content_length:
                try:
                    temp_path.unlink(missing_ok=True)
                except Exception:
                    pass
                self._write_json(handler,
                                 400,
                                 {"ok": False, "error": f"Incomplete upload ({written}/{content_length} bytes)."})
                return

            temp_path.replace(destination)
        except Exception as exc:
            try:
                temp_path.unlink(missing_ok=True)
            except Exception:
                pass
            self._write_json(handler, 500, {"ok": False, "error": f"Failed to store upload: {exc}"})
            return

        relative_path = str(destination.relative_to(self.ingest_root)) if not is_preview_upload else str(destination)
        self.log(
            f"Upload received device={device_id} job={job_id} kind={kind} "
            f"bytes={content_length} file={relative_path}"
        )

        if is_preview_upload:
            self.event_queue.put((
                "preview_upload_received",
                {
                    "device_id": device_id,
                    "device_name": device_name,
                    "request_id": request_id,
                    "batch_id": batch_id,
                    "kind": kind,
                    "path": str(destination),
                    "bytes": content_length,
                    "received_at": datetime.utcnow().isoformat() + "Z",
                },
            ))

        self._write_json(handler,
                         200,
                         {
                             "ok": True,
                             "stored_relative_path": relative_path,
                             "bytes": content_length,
                             "received_at": datetime.utcnow().isoformat() + "Z",
                         })

    def _preview_destination(self,
                             target_dir: Path,
                             kind: str,
                             device_id: str,
                             device_name: str,
                             fallback_filename: str) -> Path:
        device_part = _safe_component(device_name, fallback="")
        id_part = _safe_component(device_id, fallback="unknown-device")
        short_id = id_part[:8] if id_part else "unknown"
        if device_part and device_part.lower() not in {"unknown-name", "unknown"}:
            stem = f"{target_dir.name}_{device_part}_{short_id}"
        else:
            stem = f"{target_dir.name}_{short_id or Path(fallback_filename).stem or 'preview'}"
        suffix = ".jpg" if kind == "preview_photo" else ".json"
        return target_dir / f"{stem}{suffix}"

    def _unique_destination(self, candidate: Path) -> Path:
        if not candidate.exists():
            return candidate

        stem = candidate.stem
        suffix = candidate.suffix
        index = 1
        while True:
            next_candidate = candidate.with_name(f"{stem}_{index}{suffix}")
            if not next_candidate.exists():
                return next_candidate
            index += 1

    def _write_json(self,
                    handler: BaseHTTPRequestHandler,
                    status_code: int,
                    payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload).encode("utf-8")
        handler.send_response(status_code)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(encoded)))
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.wfile.write(encoded)
