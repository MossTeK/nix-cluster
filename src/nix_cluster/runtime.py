from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from typing import Any


def _base64_text(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def _encode_json_payload(payload: dict[str, Any]) -> str:
    return json.dumps(payload, sort_keys=True)


def _as_int(value: Any) -> int:
    if value in (None, ""):
        return 0
    if isinstance(value, int):
        return value
    return int(str(value), 0)


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

    @staticmethod
    def _kv_field(entry: dict[str, Any], snake_case: str, camel_case: str) -> Any:
        if snake_case in entry:
            return entry[snake_case]
        return entry.get(camel_case)

    def _serialize_put_request(self, key: str, value_text: str, lease_id: int = 0) -> dict[str, Any]:
        request = {
            "key": _base64_text(key.encode("utf-8")),
            "value": _base64_text(value_text.encode("utf-8")),
        }
        if lease_id:
            request["lease"] = int(lease_id)
        return request

    def _decode_range_entry(self, entry: dict[str, Any]) -> dict[str, Any]:
        key = base64.b64decode(entry["key"]).decode("utf-8")
        raw_value = base64.b64decode(entry["value"]).decode("utf-8")
        try:
            value: Any = json.loads(raw_value)
        except json.JSONDecodeError:
            value = raw_value

        return {
            "key": key,
            "value": value,
            "create_revision": _as_int(self._kv_field(entry, "create_revision", "createRevision")),
            "mod_revision": _as_int(self._kv_field(entry, "mod_revision", "modRevision")),
            "version": _as_int(entry.get("version")),
            "lease": _as_int(entry.get("lease")),
        }

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
            self._serialize_put_request(key, _encode_json_payload(payload)),
            timeout=3,
        )

    def put_json_with_lease(self, key: str, payload: dict[str, Any], lease_id: int) -> None:
        self._request_json(
            "/v3/kv/put",
            self._serialize_put_request(key, _encode_json_payload(payload), lease_id=lease_id),
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
                            **self._serialize_put_request(key, _encode_json_payload(payload)),
                        }
                    }
                    for key, payload in entries.items()
                ],
                "failure": [],
            },
            timeout=4,
        )

    def get_key(self, key: str) -> dict[str, Any] | None:
        payload = self._request_json(
            "/v3/kv/range",
            {
                "key": _base64_text(key.encode("utf-8")),
                "limit": 1,
            },
            timeout=3,
        )

        entries = payload.get("kvs", [])
        if not entries:
            return None
        return self._decode_range_entry(entries[0])

    def get_prefix(self, prefix: str) -> dict[str, dict[str, Any]]:
        return {key: entry["value"] for key, entry in self.get_prefix_entries(prefix).items()}

    def get_prefix_entries(self, prefix: str) -> dict[str, dict[str, Any]]:
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
            decoded = self._decode_range_entry(entry)
            items[decoded["key"]] = decoded
        return items

    def grant_lease(self, ttl: int) -> int:
        response = self._request_json(
            "/v3/lease/grant",
            {
                "TTL": int(ttl),
            },
            timeout=3,
        )
        return _as_int(response.get("ID"))

    def revoke_lease(self, lease_id: int) -> None:
        if not lease_id:
            return
        self._request_json(
            "/v3/lease/revoke",
            {
                "ID": int(lease_id),
            },
            timeout=3,
        )

    def put_json_if_absent(self, key: str, payload: dict[str, Any], lease_id: int = 0) -> bool:
        response = self._request_json(
            "/v3/kv/txn",
            {
                "compare": [
                    {
                        "target": "CREATE",
                        "result": "EQUAL",
                        "key": _base64_text(key.encode("utf-8")),
                        "create_revision": 0,
                    }
                ],
                "success": [
                    {
                        "request_put": self._serialize_put_request(key, _encode_json_payload(payload), lease_id=lease_id),
                    }
                ],
                "failure": [],
            },
            timeout=4,
        )
        return bool(response.get("succeeded"))

    def replace_json_if_lease(self, key: str, expected_lease_id: int, payload: dict[str, Any], lease_id: int = 0) -> bool:
        response = self._request_json(
            "/v3/kv/txn",
            {
                "compare": [
                    {
                        "target": "LEASE",
                        "result": "EQUAL",
                        "key": _base64_text(key.encode("utf-8")),
                        "lease": int(expected_lease_id),
                    }
                ],
                "success": [
                    {
                        "request_put": self._serialize_put_request(key, _encode_json_payload(payload), lease_id=lease_id),
                    }
                ],
                "failure": [],
            },
            timeout=4,
        )
        return bool(response.get("succeeded"))
