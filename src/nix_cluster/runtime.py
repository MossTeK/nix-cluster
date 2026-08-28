from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from typing import Any


# Encode bytes the way etcd's JSON API expects keys and values.
def _base64_text(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


# Serialize payloads with stable key order so repeated writes are predictable.
def _encode_json_payload(payload: dict[str, Any]) -> str:
    return json.dumps(payload, sort_keys=True)


# Parse etcd numeric fields, which may arrive as strings or be missing.
def _as_int(value: Any) -> int:
    if value in (None, ""):
        return 0
    if isinstance(value, int):
        return value
    return int(str(value), 0)


# Return the byte just after a prefix, for etcd range scans.
def prefix_range_end(prefix: bytes) -> bytes:
    buffer = bytearray(prefix)
    for index in range(len(buffer) - 1, -1, -1):
        if buffer[index] != 0xFF:
            buffer[index] += 1
            return bytes(buffer[: index + 1])
    return prefix + b"\x00"


# Raised when etcd asks writers to back off instead of accepting a request.
class RuntimeStoreRateLimited(urllib.error.URLError):
    def __init__(self, endpoint: str, retry_after: float | None = None, message: str = "HTTP Error 429: Too Many Requests"):
        # Keep the endpoint and optional Retry-After value with the normal URL error.
        super().__init__(message)
        self.endpoint = endpoint
        self.retry_after = retry_after


class RuntimeStoreWriteBlocked(RuntimeStoreRateLimited):
    """Raised when etcd accepts reads but rejects writes, commonly ALARM NOSPACE."""


# Pull a numeric Retry-After header out of an HTTP error when etcd sends one.
def _retry_after_seconds(error: urllib.error.HTTPError) -> float | None:
    retry_after = error.headers.get("Retry-After")
    if retry_after is None:
        return None
    try:
        return max(0.0, float(retry_after))
    except (TypeError, ValueError):
        return None


# Tiny etcd v3 JSON client used by the HA reporter, scheduler, and ingress router.
class EtcdClient:
    def __init__(self, endpoint: str):
        # Remember the base HTTP endpoint without a trailing slash.
        self.endpoint = endpoint.rstrip("/")

    @staticmethod
    def _kv_field(entry: dict[str, Any], snake_case: str, camel_case: str) -> Any:
        # Read fields from either etcd naming style used across versions.
        if snake_case in entry:
            return entry[snake_case]
        return entry.get(camel_case)

    def _serialize_put_request(self, key: str, value_text: str, lease_id: int = 0) -> dict[str, Any]:
        # Build the JSON body fragment etcd wants for a key/value write.
        request = {
            "key": _base64_text(key.encode("utf-8")),
            "value": _base64_text(value_text.encode("utf-8")),
        }
        if lease_id:
            request["lease"] = int(lease_id)
        return request

    def _decode_range_entry(self, entry: dict[str, Any]) -> dict[str, Any]:
        # Decode one etcd range result into normal Python strings and JSON values.
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
        # POST JSON to etcd and translate common backoff/write-block errors.
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
                try:
                    body = error.read().decode("utf-8", errors="replace")
                except Exception:
                    body = ""
                message = body.strip() or str(error)
                if "database space exceeded" in message.lower() or "nospace" in message.lower():
                    raise RuntimeStoreWriteBlocked(self.endpoint, retry_after=_retry_after_seconds(error), message=message) from error
                raise RuntimeStoreRateLimited(self.endpoint, retry_after=_retry_after_seconds(error), message=message) from error
            raise

        if not body:
            return {}
        return json.loads(body)

    def put_json(self, key: str, payload: dict[str, Any]) -> None:
        # Write a JSON payload to one etcd key without a lease.
        self._request_json(
            "/v3/kv/put",
            self._serialize_put_request(key, _encode_json_payload(payload)),
            timeout=3,
        )

    def put_json_with_lease(self, key: str, payload: dict[str, Any], lease_id: int) -> None:
        # Write a JSON payload tied to an existing etcd lease.
        self._request_json(
            "/v3/kv/put",
            self._serialize_put_request(key, _encode_json_payload(payload), lease_id=lease_id),
            timeout=3,
        )

    def put_json_many(self, entries: dict[str, dict[str, Any]]) -> None:
        # Write several JSON payloads in one etcd transaction.
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

    def health(self) -> dict[str, Any]:
        # Read etcd's lightweight health endpoint.
        request = urllib.request.Request(f"{self.endpoint}/health", method="GET")
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            if body:
                return json.loads(body)
            raise
        return json.loads(body) if body else {}

    def alarm_list(self) -> dict[str, Any]:
        # Return active etcd maintenance alarms, such as NOSPACE.
        return self._request_json("/v3/maintenance/alarm", {"action": "GET"}, timeout=4)

    def alarm_disarm(self) -> dict[str, Any]:
        # Ask etcd to clear active alarms after maintenance has made that safe.
        return self._request_json("/v3/maintenance/alarm", {"action": "DEACTIVATE"}, timeout=10)

    def endpoint_status(self) -> dict[str, Any]:
        # Read maintenance status, mainly for revision and database-size checks.
        return self._request_json("/v3/maintenance/status", {}, timeout=10)

    def compact(self, revision: int) -> dict[str, Any]:
        # Compact old etcd revisions up to the requested revision.
        return self._request_json("/v3/kv/compaction", {"revision": int(revision), "physical": False}, timeout=30)

    def defragment(self) -> dict[str, Any]:
        # Run etcd defragmentation to reclaim backend database space.
        return self._request_json("/v3/maintenance/defragment", {}, timeout=120)

    def get_key(self, key: str) -> dict[str, Any] | None:
        # Fetch one etcd key, returning decoded metadata or None if it is absent.
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
        # Fetch all JSON values under a prefix, keyed by their full etcd key.
        return {key: entry["value"] for key, entry in self.get_prefix_entries(prefix).items()}

    def get_prefix_entries(self, prefix: str) -> dict[str, dict[str, Any]]:
        # Fetch all decoded key/value entries under an etcd prefix.
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
        # Create a lease and return its numeric id.
        response = self._request_json(
            "/v3/lease/grant",
            {
                "TTL": int(ttl),
            },
            timeout=3,
        )
        return _as_int(response.get("ID"))

    def revoke_lease(self, lease_id: int) -> None:
        # Release a lease when this process no longer owns it.
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
        # Create a key only if nobody else has created it yet.
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
        # Replace a key only when it is still attached to the lease we expect.
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
