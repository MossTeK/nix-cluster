from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from typing import Any


def _base64_text(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def prefix_range_end(prefix: bytes) -> bytes:
    buffer = bytearray(prefix)
    for index in range(len(buffer) - 1, -1, -1):
        if buffer[index] != 0xFF:
            buffer[index] += 1
            return bytes(buffer[: index + 1])
    return prefix + b"\x00"


class RuntimeStoreRateLimited(urllib.error.URLError):
    def __init__(self, endpoint: str, retry_after: float | None = None, message: str = "HTTP Error 429: Too Many Requests"):
        super().__init__(message)
        self.endpoint = endpoint
        self.retry_after = retry_after


def _retry_after_seconds(error: urllib.error.HTTPError) -> float | None:
    retry_after = error.headers.get("Retry-After")
    if retry_after is None:
        return None
    try:
        return max(0.0, float(retry_after))
    except (TypeError, ValueError):
        return None


class EtcdClient:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint.rstrip("/")

    def _request_json(self, path: str, payload: dict[str, Any], timeout: int) -> dict[str, Any]:
        request = urllib.request.Request(
            f"{self.endpoint}{path}",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            if error.code == 429:
                raise RuntimeStoreRateLimited(self.endpoint, retry_after=_retry_after_seconds(error)) from error
            raise

        if not body:
            return {}
        return json.loads(body)

    def put_json(self, key: str, payload: dict[str, Any]) -> None:
        self._request_json(
            "/v3/kv/put",
            {
                "key": _base64_text(key.encode("utf-8")),
                "value": _base64_text(json.dumps(payload, sort_keys=True).encode("utf-8")),
            },
            timeout=3,
        )

    def put_json_many(self, entries: dict[str, dict[str, Any]]) -> None:
        if not entries:
            return

        self._request_json(
            "/v3/kv/txn",
            {
                "compare": [],
                "success": [
                    {
                        "request_put": {
                            "key": _base64_text(key.encode("utf-8")),
                            "value": _base64_text(json.dumps(payload, sort_keys=True).encode("utf-8")),
                        }
                    }
                    for key, payload in entries.items()
                ],
                "failure": [],
            },
            timeout=4,
        )

    def get_prefix(self, prefix: str) -> dict[str, dict[str, Any]]:
        prefix_bytes = prefix.encode("utf-8")
        payload = self._request_json(
            "/v3/kv/range",
            {
                "key": _base64_text(prefix_bytes),
                "range_end": _base64_text(prefix_range_end(prefix_bytes)),
            },
            timeout=4,
        )

        items: dict[str, dict[str, Any]] = {}
        for entry in payload.get("kvs", []):
            key = base64.b64decode(entry["key"]).decode("utf-8")
            value = json.loads(base64.b64decode(entry["value"]).decode("utf-8"))
            items[key] = value
        return items
