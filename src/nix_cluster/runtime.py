from __future__ import annotations

import base64
import json
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


class EtcdClient:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint.rstrip("/")

    def put_json(self, key: str, payload: dict[str, Any]) -> None:
        request = urllib.request.Request(
            f"{self.endpoint}/v3/kv/put",
            data=json.dumps(
                {
                    "key": _base64_text(key.encode("utf-8")),
                    "value": _base64_text(json.dumps(payload, sort_keys=True).encode("utf-8")),
                }
            ).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=3):
            return

    def get_prefix(self, prefix: str) -> dict[str, dict[str, Any]]:
        prefix_bytes = prefix.encode("utf-8")
        request = urllib.request.Request(
            f"{self.endpoint}/v3/kv/range",
            data=json.dumps(
                {
                    "key": _base64_text(prefix_bytes),
                    "range_end": _base64_text(prefix_range_end(prefix_bytes)),
                }
            ).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=4) as response:
            payload = json.loads(response.read().decode("utf-8"))

        items: dict[str, dict[str, Any]] = {}
        for entry in payload.get("kvs", []):
            key = base64.b64decode(entry["key"]).decode("utf-8")
            value = json.loads(base64.b64decode(entry["value"]).decode("utf-8"))
            items[key] = value
        return items
