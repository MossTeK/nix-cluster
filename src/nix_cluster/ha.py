from __future__ import annotations

import hashlib
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import uuid
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from .config import RuntimeConfig
from .core import atomic_write_json, atomic_write_text, configure_logging
from .ingress import route_status_for_unit
from .runtime import EtcdClient, RuntimeStoreRateLimited, RuntimeStoreWriteBlocked

ACTIVE_STATES = {"active", "activating", "reloading"}
HEALTHY_ACTIVE_STATES = {"active", "reloading"}
REPEATED_WARNING_INTERVAL_SECONDS = 60.0
RECONCILER_COMMAND_TIMEOUT_SECONDS = 60
MIN_AVAILABLE_MEMORY_BYTES = 512 * 1024 * 1024
MIN_STATE_FREE_BYTES = 2 * 1024 * 1024 * 1024
CLUSTER_STATE_KEY = "/nix-cluster/cluster-state"
NODE_DETAIL_PREFIX = "/nix-cluster/node-details"
MANAGED_UNITS_KEY = "/nix-cluster/scheduler/managed-units"
NODE_HEARTBEAT_PREFIX = "/nix-cluster/heartbeats"
REQUEST_COMPLETE_TTL_SECONDS = 300
IGNORED_DISK_FSTYPES = {
    "autofs",
    "binfmt_misc",
    "bpf",
    "cgroup",
    "cgroup2",
    "configfs",
    "debugfs",
    "devpts",
    "devtmpfs",
    "fusectl",
    "hugetlbfs",
    "mqueue",
    "proc",
    "pstore",
    "securityfs",
    "squashfs",
    "sysfs",
    "tmpfs",
    "tracefs",
}


# Convert loose runtime data to int without breaking the long-running loop.
def _safe_int(raw: Any, default: int = 0) -> int:
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


# Convert loose runtime data to float without breaking the long-running loop.
def _safe_float(raw: Any, default: float = 0.0) -> float:
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


# Remove repeated unit names while keeping the user's configured order.
def _dedupe_preserve_order(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if not value or value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


# Turn an etcd write/backoff exception into a log event name and delay.
def _runtime_store_warning_details(error: RuntimeStoreRateLimited, default_retry_after: float) -> tuple[str, float]:
    retry_after = error.retry_after if error.retry_after is not None else default_retry_after
    if isinstance(error, RuntimeStoreWriteBlocked):
        return "runtime_store_write_blocked", retry_after
    return "runtime_store_rate_limited", retry_after


# Hash a service payload while ignoring its timestamp-only churn.
def _payload_digest(payload: dict[str, Any]) -> str:
    stable_payload = dict(payload)
    stable_payload.pop("observed_at", None)
    encoded = json.dumps(stable_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


# Publish this node's systemd service health to files, metrics, and etcd.
class ServiceReporter:
    def __init__(self, config_path: str | None = None):
        # Load runtime config and prepare change tracking for reported units.
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-reporter")
        self.hostname = socket.gethostname()
        self.previous_states: dict[str, bool] = {}
        self.previous_payload_hashes: dict[str, str] = {}
        self.previous_etcd_write_at: dict[str, float] = {}
        self.last_runtime_store_warning: tuple[str, str] | None = None
        self.last_runtime_store_warning_at = 0.0
        self.instance_id = uuid.uuid4().hex
        self.sequence = 0
        self.last_collection_duration_seconds = 0.0

    def log_runtime_store_warning(self, endpoint: str, message: str, *args: Any) -> None:
        # Log repeated etcd warnings at a slower pace so journals stay readable.
        rendered = message % args if args else message
        signature = (endpoint, rendered)
        now = time.monotonic()
        if signature == self.last_runtime_store_warning and (now - self.last_runtime_store_warning_at) < REPEATED_WARNING_INTERVAL_SECONDS:
            return
        self.last_runtime_store_warning = signature
        self.last_runtime_store_warning_at = now
        self.logger.warning(message, *args)

    def run_command(self, command: list[str]) -> str:
        # Run a system command and return stdout, raising on failure.
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"command failed: {' '.join(command)}")
        return result.stdout

    def list_all_service_units(self) -> set[str]:
        # Ask systemd for every known service unit on this node.
        output = self.run_command([
            "systemctl", "list-unit-files", "--type=service", "--plain", "--no-legend", "--no-pager",
        ])
        units: set[str] = set()
        for line in output.splitlines():
            parts = line.split()
            if parts and parts[0].endswith(".service"):
                units.add(parts[0])
        return units

    def collect_unit_status(self, unit: str) -> dict[str, Any]:
        # Collect the systemd fields nix-cluster uses to decide service health.
        output = self.run_command([
            "systemctl", "show", unit,
            "--property=Id", "--property=LoadState", "--property=ActiveState", "--property=SubState",
            "--property=UnitFileState", "--property=Result", "--property=ExecMainPID",
            "--property=ExecMainStatus", "--property=ActiveEnterTimestamp",
        ])
        values: dict[str, str] = {}
        for line in output.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value

        active_state = values.get("ActiveState", "unknown")
        return {
            "host": self.hostname,
            "unit": values.get("Id", unit) or unit,
            "load_state": values.get("LoadState", "unknown"),
            "active_state": active_state,
            "sub_state": values.get("SubState", "unknown"),
            "unit_file_state": values.get("UnitFileState", "unknown"),
            "result": values.get("Result", "unknown"),
            "exec_main_pid": values.get("ExecMainPID", "0"),
            "exec_main_status": values.get("ExecMainStatus", "0"),
            "active_enter_timestamp": values.get("ActiveEnterTimestamp", ""),
            "healthy": active_state in HEALTHY_ACTIVE_STATES and values.get("LoadState", "") == "loaded",
            "observed_at": int(time.time()),
        }

    def collect_unit_statuses(self, units: list[str], observed_at: int) -> dict[str, dict[str, Any]]:
        """Collect selected units with one bounded systemctl invocation."""
        if not units:
            return {}
        properties = [
            "Id", "LoadState", "ActiveState", "SubState", "UnitFileState",
            "Result", "ExecMainPID", "ExecMainStatus", "ActiveEnterTimestamp",
        ]
        command = ["systemctl", "show", *units, *[f"--property={name}" for name in properties]]
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=max(1, self.config.ha.reporting.collection_deadline_seconds),
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "batched systemctl show failed")
        services: dict[str, dict[str, Any]] = {}
        for block in result.stdout.strip().split("\n\n"):
            values = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
            unit = values.get("Id", "")
            if not unit:
                continue
            active_state = values.get("ActiveState", "unknown")
            services[unit] = {
                "host": self.hostname,
                "unit": unit,
                "load_state": values.get("LoadState", "unknown"),
                "active_state": active_state,
                "sub_state": values.get("SubState", "unknown"),
                "unit_file_state": values.get("UnitFileState", "unknown"),
                "result": values.get("Result", "unknown"),
                "exec_main_pid": values.get("ExecMainPID", "0"),
                "exec_main_status": values.get("ExecMainStatus", "0"),
                "active_enter_timestamp": values.get("ActiveEnterTimestamp", ""),
                "healthy": active_state in HEALTHY_ACTIVE_STATES and values.get("LoadState", "") == "loaded",
                "observed_at": observed_at,
                "reporter_instance_id": self.instance_id,
                "sequence": self.sequence,
            }
        return services

    def build_metric_lines(self, services: dict[str, dict[str, Any]]) -> str:
        # Render Prometheus textfile metrics for the latest service snapshot.
        lines = [
            "# HELP nix_cluster_service_healthy Whether a reported systemd unit is healthy.",
            "# TYPE nix_cluster_service_healthy gauge",
        ]
        for unit, payload in sorted(services.items()):
            healthy = "1" if payload["healthy"] else "0"
            active_state = payload["active_state"].replace('"', '\\"')
            sub_state = payload["sub_state"].replace('"', '\\"')
            lines.append(
                f'nix_cluster_service_healthy{{host="{self.hostname}",service="{unit}",active_state="{active_state}",sub_state="{sub_state}"}} {healthy}'
            )
        lines.extend([
            "# HELP nix_cluster_report_timestamp_seconds Unix timestamp of the most recent reporter pass.",
            "# TYPE nix_cluster_report_timestamp_seconds gauge",
            f'nix_cluster_report_timestamp_seconds{{host="{self.hostname}"}} {int(time.time())}',
            "# HELP nix_cluster_report_collection_duration_seconds Duration of the latest service collection pass.",
            "# TYPE nix_cluster_report_collection_duration_seconds gauge",
            f'nix_cluster_report_collection_duration_seconds{{host="{self.hostname}"}} {self.last_collection_duration_seconds:.3f}',
        ])
        return "\n".join(lines) + "\n"

    def selected_units(self, all_units: set[str]) -> list[str]:
        # Apply reporting mode and tracked-unit config to choose units to publish.
        reporting_cfg = self.config.ha.reporting
        tracked_units = set(self.config.observability.tracked_units)
        configured_units = set(reporting_cfg.services)

        if reporting_cfg.mode in {"only", "none_except"}:
            units = set(configured_units)
            if reporting_cfg.include_tracked_units:
                units |= tracked_units
            return sorted(unit for unit in units if unit)

        units = set(all_units)
        if reporting_cfg.include_tracked_units:
            units |= tracked_units
        units -= configured_units
        return sorted(unit for unit in units if unit)

    def run(self) -> None:
        # Main reporter loop: sample systemd, write local files, publish to etcd.
        if not (self.config.ha.enable and self.config.ha.reporting.enable):
            self.logger.info("service reporting disabled")
            return

        snapshot_path = Path(self.config.directories.state) / "ha" / "service-health.json"
        metrics_path = Path(self.config.directories.metrics) / "service-health.prom"
        runtime_store = self.config.ha.runtime_store
        etcd = EtcdClient(runtime_store.endpoint) if runtime_store.type == "etcd" and runtime_store.endpoint else None
        key_prefix = runtime_store.key_prefix.rstrip("/")
        interval = max(15, self.config.ha.reporting.interval_seconds)
        heartbeat_refresh_interval = max(float(interval), float(max(1, runtime_store.stale_after_seconds)) / 2.0)
        backoff_until = 0.0

        self.logger.info("starting service reporter on %s", self.hostname)
        while True:
            try:
                loop_started = time.monotonic()
                observed_at = int(time.time())
                self.sequence += 1
                if etcd and time.monotonic() >= backoff_until:
                    etcd.put_json(
                        f"{NODE_HEARTBEAT_PREFIX}/{self.hostname}",
                        {
                            "host": self.hostname,
                            "observed_at": observed_at,
                            "reporter_instance_id": self.instance_id,
                            "sequence": self.sequence,
                        },
                    )
                units = self.selected_units(self.list_all_service_units())
                services = self.collect_unit_statuses(units, observed_at)
                self.last_collection_duration_seconds = time.monotonic() - loop_started
                if self.last_collection_duration_seconds > self.config.ha.reporting.collection_deadline_seconds:
                    self.logger.warning(
                        "reporter_collection_deadline_exceeded host=%s duration=%.3f deadline=%s",
                        self.hostname,
                        self.last_collection_duration_seconds,
                        self.config.ha.reporting.collection_deadline_seconds,
                    )
                etcd_updates: dict[str, dict[str, Any]] = {}
                for unit, payload in services.items():
                    payload["collection_duration_seconds"] = round(self.last_collection_duration_seconds, 3)
                    prior = self.previous_states.get(unit)
                    current = bool(payload["healthy"])
                    if prior is None or prior != current:
                        self.logger.info(
                            "service_state_change host=%s unit=%s healthy=%s active_state=%s sub_state=%s",
                            self.hostname, unit, str(current).lower(), payload["active_state"], payload["sub_state"],
                        )
                    self.previous_states[unit] = current
                    if etcd:
                        key = f"{key_prefix}/{self.hostname}/{unit}"
                        digest = _payload_digest(payload)
                        last_write_at = self.previous_etcd_write_at.get(key, 0.0)
                        if digest != self.previous_payload_hashes.get(key) or (time.monotonic() - last_write_at) >= heartbeat_refresh_interval:
                            etcd_updates[key] = payload
                            self.previous_payload_hashes[key] = digest

                atomic_write_json(snapshot_path, {"host": self.hostname, "observed_at": int(time.time()), "services": services})
                atomic_write_text(metrics_path, self.build_metric_lines(services))
                if etcd and time.monotonic() >= backoff_until:
                    etcd.put_json_many(etcd_updates)
                    write_time = time.monotonic()
                    for key in etcd_updates:
                        self.previous_etcd_write_at[key] = write_time
            except RuntimeStoreRateLimited as error:
                event, retry_after = _runtime_store_warning_details(error, max(5.0, float(interval)))
                backoff_until = time.monotonic() + retry_after
                self.log_runtime_store_warning(
                    runtime_store.endpoint,
                    "%s endpoint=%s retry_after=%.1fs",
                    event,
                    runtime_store.endpoint,
                    retry_after,
                )
            except urllib.error.URLError as error:
                self.log_runtime_store_warning(
                    runtime_store.endpoint,
                    "runtime_store_unreachable endpoint=%s error=%s",
                    runtime_store.endpoint,
                    error,
                )
            except Exception as error:
                self.logger.exception("reporter_loop_failed: %s", error)
            time.sleep(interval)


# Keep a short list of local critical services alive on each node.
class LocalRecoveryMonitor:
    def __init__(self, config_path: str | None = None):
        # Load recovery config and remember prior health for change-only logging.
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-recovery")
        self.hostname = socket.gethostname()
        self.previous_states: dict[str, bool] = {}

    def run_command(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        # Run recovery commands with a timeout so the loop cannot hang forever.
        try:
            return subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
                timeout=RECONCILER_COMMAND_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or ""
            stderr = error.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode(errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            return subprocess.CompletedProcess(
                command,
                124,
                stdout=stdout,
                stderr=stderr or f"command timed out after {RECONCILER_COMMAND_TIMEOUT_SECONDS}s",
            )

    def collect_unit_status(self, unit: str) -> dict[str, Any]:
        # Collect enough systemd state to decide if a critical unit needs help.
        result = self.run_command([
            "systemctl", "show", unit,
            "--property=Id", "--property=LoadState", "--property=ActiveState", "--property=SubState",
            "--property=Result",
        ])
        values: dict[str, str] = {}
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key] = value

        load_state = values.get("LoadState", "not-found" if result.returncode != 0 else "unknown")
        active_state = values.get("ActiveState", "unknown")
        return {
            "unit": values.get("Id", unit) or unit,
            "load_state": load_state,
            "active_state": active_state,
            "sub_state": values.get("SubState", "unknown"),
            "result": values.get("Result", "unknown"),
            "healthy": load_state == "loaded" and active_state in HEALTHY_ACTIVE_STATES,
        }

    def recover_unit(self, unit: str, status: dict[str, Any]) -> bool:
        # Reset and start an unhealthy critical unit unless recovery is dry-run.
        if status.get("load_state") != "loaded":
            self.logger.warning(
                "critical_unit_missing host=%s unit=%s load_state=%s",
                self.hostname,
                unit,
                status.get("load_state"),
            )
            return False

        if self.config.local_recovery.dry_run:
            self.logger.warning(
                "critical_unit_recovery_dry_run host=%s unit=%s active_state=%s sub_state=%s",
                self.hostname,
                unit,
                status.get("active_state"),
                status.get("sub_state"),
            )
            return True

        self.logger.warning(
            "critical_unit_recovery_attempt host=%s unit=%s active_state=%s sub_state=%s result=%s",
            self.hostname,
            unit,
            status.get("active_state"),
            status.get("sub_state"),
            status.get("result"),
        )
        self.run_command(["sudo", "systemctl", "reset-failed", unit])
        result = self.run_command(["sudo", "systemctl", "start", unit])
        if result.returncode == 0:
            self.logger.info("critical_unit_recovery_success host=%s unit=%s", self.hostname, unit)
            return True

        self.logger.error(
            "critical_unit_recovery_failed host=%s unit=%s error=%s",
            self.hostname,
            unit,
            result.stderr.strip() or result.stdout.strip() or f"exit_{result.returncode}",
        )
        return False

    def run(self) -> None:
        # Main recovery loop for configured critical units.
        recovery_cfg = self.config.local_recovery
        if not recovery_cfg.enable:
            self.logger.info("local recovery monitor disabled")
            return

        interval = max(15, recovery_cfg.interval_seconds)
        units = _dedupe_preserve_order(recovery_cfg.critical_units)
        if not units:
            self.logger.info("local recovery monitor has no critical units")
            return

        self.logger.info("starting local recovery monitor on %s units=%s", self.hostname, ",".join(units))
        while True:
            try:
                for unit in units:
                    status = self.collect_unit_status(unit)
                    healthy = bool(status.get("healthy"))
                    if self.previous_states.get(unit) != healthy:
                        self.logger.info(
                            "critical_unit_state host=%s unit=%s healthy=%s active_state=%s sub_state=%s load_state=%s",
                            self.hostname,
                            unit,
                            str(healthy).lower(),
                            status.get("active_state"),
                            status.get("sub_state"),
                            status.get("load_state"),
                        )
                    self.previous_states[unit] = healthy
                    if not healthy:
                        self.recover_unit(unit, status)
            except Exception as error:
                self.logger.exception("recovery_loop_failed: %s", error)
            time.sleep(interval)


# Apply scheduler placement locally by starting or stopping managed units.
class WorkerReconciler:
    def __init__(self, config_path: str | None = None):
        # Load scheduler settings and remember previous assignments for logging.
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-reconciler")
        self.hostname = socket.gethostname()
        self.previous_assignments: dict[str, str | None] = {}
        self.last_runtime_store_warning: tuple[str, str] | None = None
        self.last_runtime_store_warning_at = 0.0
        self.owned_leases: dict[str, dict[str, Any]] = {}
        self.lease_lock = threading.Lock()
        self.lease_transient_failures: dict[str, int] = {}
        self.resource_samples: list[dict[str, Any]] = []
        self.storage_healthy_observations = 0

    @staticmethod
    def classify_storage_command_failure(output: str) -> str:
        normalized = output.lower()
        if "hostid" in normalized and ("mismatch" in normalized or "last accessed by another system" in normalized):
            return "warning_hostid_mismatch"
        if "zfs-8000-ey" in normalized:
            return "warning_hostid_mismatch"
        if "permanent errors" in normalized or "data corruption" in normalized or "zfs-8000-8a" in normalized:
            return "unhealthy_data_corruption"
        degraded_terms = ("degraded", "faulted", "unavail", "offline", "removed", "insufficient replicas")
        if any(term in normalized for term in degraded_terms):
            return "unhealthy_degraded_pool"
        return "unknown_probe_failed"

    def collect_storage_health(self, now: int) -> dict[str, Any]:
        settings = self.config.ha.scheduler.storage_health
        if not settings.enable:
            self.storage_healthy_observations = 0
            return {
                "state_storage_health": "disabled",
                "state_storage_healthy": True,
                "state_storage_observed_at": now,
                "state_storage_reason": "probe_disabled",
                "state_storage_healthy_observations": 0,
            }

        state = "healthy"
        reason = "checks_passed"
        try:
            missing_mounts = [mount for mount in settings.required_mounts if not os.path.ismount(mount)]
            if missing_mounts:
                state = "unhealthy_required_mount_missing"
                reason = "required_mount_missing"
            elif settings.command:
                result = subprocess.run(
                    settings.command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=max(1, settings.timeout_seconds),
                    check=False,
                )
                if result.returncode != 0:
                    output = f"{result.stdout}\n{result.stderr}"
                    state = self.classify_storage_command_failure(output)
                    reason = state

            if state == "healthy":
                probe_dir = Path(settings.probe_path)
                probe_file = probe_dir / f".nix-cluster-storage-probe-{os.getpid()}"
                token = f"{self.hostname}:{now}\n".encode("utf-8")
                descriptor = os.open(probe_file, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
                try:
                    os.write(descriptor, token)
                    os.fsync(descriptor)
                    os.lseek(descriptor, 0, os.SEEK_SET)
                    if os.read(descriptor, len(token)) != token:
                        state = "unhealthy_data_corruption"
                        reason = "read_write_probe_mismatch"
                finally:
                    os.close(descriptor)
                    probe_file.unlink(missing_ok=True)
        except subprocess.TimeoutExpired:
            state = "unknown_probe_timeout"
            reason = "health_command_timeout"
        except OSError:
            state = "unknown_probe_failed"
            reason = "read_write_probe_error"

        if state == "healthy":
            self.storage_healthy_observations += 1
        else:
            self.storage_healthy_observations = 0
        threshold = max(1, settings.healthy_observation_threshold)
        effective_healthy = state == "healthy" and self.storage_healthy_observations >= threshold
        if state == "healthy" and not effective_healthy:
            state = "recovering"
            reason = "healthy_observation_threshold"
        return {
            "state_storage_health": state,
            "state_storage_healthy": effective_healthy,
            "state_storage_observed_at": now,
            "state_storage_reason": reason,
            "state_storage_healthy_observations": self.storage_healthy_observations,
        }

    def lease_is_locally_valid(self, unit: str) -> bool:
        with self.lease_lock:
            lease = self.owned_leases.get(unit)
            return bool(lease and time.monotonic() < float(lease.get("deadline", 0.0)))

    def stop_expired_leases(self, reason: str) -> None:
        with self.lease_lock:
            expired = [unit for unit, lease in self.owned_leases.items() if time.monotonic() >= float(lease.get("deadline", 0.0))]
        if expired:
            self.fail_closed_stop(expired, reason)
            with self.lease_lock:
                for unit in expired:
                    self.owned_leases.pop(unit, None)

    def lease_keeper(self, endpoint: str) -> None:
        interval = max(1, self.config.ha.scheduler.lease_renewal_seconds)
        ttl = max(interval * 3, self.config.ha.scheduler.lease_ttl_seconds)
        etcd = EtcdClient(endpoint)
        while True:
            with self.lease_lock:
                leases = {unit: dict(value) for unit, value in self.owned_leases.items()}
            for unit, lease in leases.items():
                try:
                    remaining = etcd.keep_alive_lease(_safe_int(lease.get("id")))
                    if remaining <= 0:
                        with self.lease_lock:
                            if unit in self.owned_leases:
                                self.owned_leases[unit]["deadline"] = 0.0
                        self.stop_expired_leases("lease_expired")
                        continue
                    with self.lease_lock:
                        current = self.owned_leases.get(unit)
                        if current and _safe_int(current.get("id")) == _safe_int(lease.get("id")):
                            current["deadline"] = time.monotonic() + min(ttl, remaining)
                            current["last_renewed_at"] = int(time.time())
                            self.lease_transient_failures[unit] = 0
                except (urllib.error.URLError, TimeoutError, OSError) as error:
                    self.lease_transient_failures[unit] = self.lease_transient_failures.get(unit, 0) + 1
                    self.log_runtime_store_warning(endpoint, "ownership_lease_renewal_unknown host=%s unit=%s error=%s", self.hostname, unit, type(error).__name__)
                    self.stop_expired_leases("lease_renewal_deadline_expired")
                except Exception as error:
                    self.logger.exception("ownership_lease_keeper_failed host=%s unit=%s error=%s", self.hostname, unit, error)
                    self.stop_expired_leases("lease_renewal_deadline_expired")
            time.sleep(interval)

    def ensure_service_lease(self, etcd: EtcdClient, ownership_key: str, unit: str, generation: int, now: int) -> bool:
        ttl = max(15, self.config.ha.scheduler.lease_ttl_seconds)
        with self.lease_lock:
            tracked = self.owned_leases.get(unit)
            if tracked and _safe_int(tracked.get("generation")) == generation and time.monotonic() < float(tracked.get("deadline", 0.0)):
                return True
        existing = etcd.get_key(ownership_key)
        payload = {"host": self.hostname, "unit": unit, "generation": generation, "observed_at": now}
        new_lease = etcd.grant_lease(ttl)
        if not new_lease:
            return False
        old_lease = 0
        if existing is None:
            acquired = etcd.put_json_if_absent(ownership_key, payload, lease_id=new_lease)
        else:
            value = existing.get("value", {})
            old_lease = _safe_int(existing.get("lease"))
            acquired = bool(
                value.get("host") == self.hostname
                and old_lease
                and etcd.replace_json_if_lease(ownership_key, old_lease, payload, lease_id=new_lease)
            )
        if not acquired:
            etcd.revoke_lease(new_lease)
            return False
        with self.lease_lock:
            self.owned_leases[unit] = {
                "id": new_lease,
                "generation": generation,
                "key": ownership_key,
                "deadline": time.monotonic() + ttl,
                "last_renewed_at": now,
            }
        if old_lease and old_lease != new_lease:
            etcd.revoke_lease(old_lease)
        return True

    def release_service_lease(self, etcd: EtcdClient, ownership_key: str, unit: str) -> None:
        existing = etcd.get_key(ownership_key)
        if existing and existing.get("value", {}).get("host") == self.hostname:
            etcd.revoke_lease(_safe_int(existing.get("lease")))
        with self.lease_lock:
            self.owned_leases.pop(unit, None)

    def fail_closed_stop(self, units: Iterable[str], reason: str) -> None:
        for unit in list(units):
            status = self.collect_unit_status(unit, int(time.time()))
            if status.get("active_state") in ACTIVE_STATES:
                self.logger.error("scheduler_lease_lost_fail_closed host=%s unit=%s reason=%s", self.hostname, unit, reason)
                self.run_command(["sudo", "systemctl", "--no-block", "stop", unit])

    def log_runtime_store_warning(self, endpoint: str, message: str, *args: Any) -> None:
        # Log repeated etcd warnings at a slower pace so journals stay readable.
        rendered = message % args if args else message
        signature = (endpoint, rendered)
        now = time.monotonic()
        if signature == self.last_runtime_store_warning and (now - self.last_runtime_store_warning_at) < REPEATED_WARNING_INTERVAL_SECONDS:
            return
        self.last_runtime_store_warning = signature
        self.last_runtime_store_warning_at = now
        self.logger.warning(message, *args)

    def run_command(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        # Run reconciler commands with a timeout and return the completed process.
        try:
            return subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
                timeout=RECONCILER_COMMAND_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or ""
            stderr = error.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode(errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            return subprocess.CompletedProcess(
                command,
                124,
                stdout=stdout,
                stderr=stderr or f"command timed out after {RECONCILER_COMMAND_TIMEOUT_SECONDS}s",
            )

    def collect_unit_status(self, unit: str, now: int) -> dict[str, Any]:
        # Collect detailed systemd status for a scheduler-managed unit.
        result = self.run_command([
            "systemctl", "show", unit,
            "--property=Id", "--property=LoadState", "--property=ActiveState", "--property=SubState",
            "--property=UnitFileState", "--property=Result", "--property=ExecMainPID",
            "--property=ExecMainStatus", "--property=ActiveEnterTimestamp",
        ])
        if result.returncode != 0:
            return {
                "host": self.hostname,
                "unit": unit,
                "load_state": "not-found",
                "active_state": "inactive",
                "sub_state": "dead",
                "unit_file_state": "unknown",
                "result": "unknown",
                "exec_main_pid": "0",
                "exec_main_status": "0",
                "active_enter_timestamp": "",
                "healthy": False,
                "observed_at": now,
            }

        values: dict[str, str] = {}
        for line in result.stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
        active_state = values.get("ActiveState", "unknown")
        load_state = values.get("LoadState", "unknown")
        return {
            "host": self.hostname,
            "unit": values.get("Id", unit) or unit,
            "load_state": load_state,
            "active_state": active_state,
            "sub_state": values.get("SubState", "unknown"),
            "unit_file_state": values.get("UnitFileState", "unknown"),
            "result": values.get("Result", "unknown"),
            "exec_main_pid": values.get("ExecMainPID", "0"),
            "exec_main_status": values.get("ExecMainStatus", "0"),
            "active_enter_timestamp": values.get("ActiveEnterTimestamp", ""),
            "healthy": active_state in HEALTHY_ACTIVE_STATES and load_state == "loaded",
            "observed_at": now,
        }

    def read_controller_status(self) -> bool:
        # Read the worker heartbeat file and treat missing status as reachable.
        if self.config.is_controller:
            return True
        status_path = Path(self.config.directories.heartbeat) / "controller-status.json"
        if not status_path.exists():
            return True
        try:
            payload = json.loads(status_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            self.logger.warning("controller_status_read_failed path=%s error=%s", status_path, error)
            return True
        return bool(payload.get("reachable", True))

    def collect_uptime_seconds(self) -> float:
        # Read this node's uptime from `/proc/uptime` for dashboard detail.
        try:
            with open("/proc/uptime", "r", encoding="utf-8") as handle:
                return _safe_float(handle.read().split()[0])
        except (OSError, IndexError):
            return 0.0

    def collect_disk_snapshots(self) -> list[dict[str, Any]]:
        # Summarize real mounted disks while skipping virtual/kernel filesystems.
        disks: list[dict[str, Any]] = []
        seen_mounts: set[str] = set()
        try:
            mount_lines = Path("/proc/mounts").read_text(encoding="utf-8").splitlines()
        except OSError:
            mount_lines = []

        for line in mount_lines:
            parts = line.split()
            if len(parts) < 3:
                continue
            filesystem, mount, fstype = parts[:3]
            if fstype in IGNORED_DISK_FSTYPES or mount in seen_mounts:
                continue
            seen_mounts.add(mount)
            try:
                stats = os.statvfs(mount)
            except OSError:
                continue
            size = stats.f_frsize * stats.f_blocks
            available = stats.f_frsize * stats.f_bavail
            free = stats.f_frsize * stats.f_bfree
            used = max(size - free, 0)
            disks.append({
                "filesystem": filesystem.replace("\\040", " "),
                "type": fstype,
                "mount": mount.replace("\\040", " "),
                "size": size,
                "used": used,
                "available": available,
                "used_percent": round((used / size) * 100, 1) if size else 0.0,
            })
        return sorted(disks, key=lambda item: str(item.get("mount", "")))

    def collect_resource_snapshot(self, now: int) -> dict[str, Any]:
        # Collect CPU, memory, disk, and controller reachability for scheduling.
        memory_total_bytes = 0
        memory_available_bytes = 0
        with open("/proc/meminfo", "r", encoding="utf-8") as handle:
            for line in handle:
                key, _, value = line.partition(":")
                parts = value.strip().split()
                if not parts:
                    continue
                bytes_value = _safe_int(parts[0]) * 1024
                if key == "MemTotal":
                    memory_total_bytes = bytes_value
                elif key == "MemAvailable":
                    memory_available_bytes = bytes_value
                elif key == "MemFree" and not memory_available_bytes:
                    memory_available_bytes = bytes_value

        state_path = Path(self.config.directories.state)
        usage_path = state_path if state_path.exists() else Path("/")
        stats = os.statvfs(usage_path)
        state_dir_total_bytes = stats.f_frsize * stats.f_blocks
        state_dir_free_bytes = stats.f_frsize * stats.f_bavail
        load_1, load_5, load_15 = os.getloadavg()
        cpu_count = max(1, os.cpu_count() or 1)
        controller_reachable = self.read_controller_status()
        storage_health = self.collect_storage_health(now)
        schedulable = (
            self.config.ha.scheduler.node_schedulable
            and bool(storage_health["state_storage_healthy"])
            and memory_available_bytes >= MIN_AVAILABLE_MEMORY_BYTES
            and state_dir_free_bytes >= MIN_STATE_FREE_BYTES
        )

        snapshot = {
            "host": self.hostname,
            "observed_at": now,
            "cpu_count": cpu_count,
            "load_1": load_1,
            "load_5": load_5,
            "load_15": load_15,
            "load_1_per_cpu": load_1 / cpu_count,
            "memory_total_bytes": memory_total_bytes,
            "memory_available_bytes": memory_available_bytes,
            "memory_available_ratio": (memory_available_bytes / memory_total_bytes) if memory_total_bytes else 0.0,
            "state_dir_path": str(usage_path),
            "state_dir_total_bytes": state_dir_total_bytes,
            "state_dir_free_bytes": state_dir_free_bytes,
            "state_dir_free_ratio": (state_dir_free_bytes / state_dir_total_bytes) if state_dir_total_bytes else 0.0,
            "controller_reachable": controller_reachable,
            "schedulable": schedulable,
            "minimum_memory_available_bytes": MIN_AVAILABLE_MEMORY_BYTES,
            "minimum_state_dir_free_bytes": MIN_STATE_FREE_BYTES,
            "node_schedulable_configured": self.config.ha.scheduler.node_schedulable,
            **storage_health,
        }
        self.resource_samples.append(dict(snapshot))
        self.resource_samples = self.resource_samples[-3:]
        if len(self.resource_samples) >= 3:
            for field in ("memory_available_bytes", "state_dir_free_bytes", "load_1_per_cpu"):
                snapshot[field] = sum(_safe_float(sample.get(field)) for sample in self.resource_samples) / len(self.resource_samples)
            snapshot["memory_available_bytes"] = int(snapshot["memory_available_bytes"])
            snapshot["state_dir_free_bytes"] = int(snapshot["state_dir_free_bytes"])
        snapshot["sample_count"] = len(self.resource_samples)
        return snapshot

    def build_node_detail(
        self,
        resource_snapshot: dict[str, Any],
        units: dict[str, dict[str, Any]],
        now: int,
    ) -> dict[str, Any]:
        # Build the richer per-node status document consumed by dashboards.
        memory_total = _safe_int(resource_snapshot.get("memory_total_bytes"))
        memory_available = _safe_int(resource_snapshot.get("memory_available_bytes"))
        memory_used = max(memory_total - memory_available, 0)
        load_per_cpu = _safe_float(resource_snapshot.get("load_1_per_cpu"))
        services = []
        for unit, payload in sorted(units.items()):
            status = payload.get("status_after") if isinstance(payload.get("status_after"), dict) else {}
            services.append({
                "name": unit,
                "load_state": status.get("load_state", "unknown"),
                "active_state": status.get("active_state", "unknown"),
                "sub_state": status.get("sub_state", "unknown"),
                "unit_file_state": status.get("unit_file_state", "unknown"),
                "result": status.get("result", "unknown"),
                "healthy": bool(status.get("healthy")),
                "main_pid": _safe_int(status.get("exec_main_pid")),
                "desired_owner": payload.get("desired_owner"),
                "desired_local": bool(payload.get("desired_local")),
                "active_local": bool(payload.get("active_local")),
                "has_placement": bool(payload.get("has_placement")),
                "last_action": payload.get("last_action"),
                "last_action_reason": payload.get("last_action_reason"),
                "last_action_success": bool(payload.get("last_action_success")),
            })

        return {
            "hostname": self.hostname,
            "observed_at": now,
            "uptime_seconds": self.collect_uptime_seconds(),
            "cpu": {
                "count": _safe_int(resource_snapshot.get("cpu_count"), 1),
                "load_1": _safe_float(resource_snapshot.get("load_1")),
                "load_5": _safe_float(resource_snapshot.get("load_5")),
                "load_15": _safe_float(resource_snapshot.get("load_15")),
                "load_1_per_cpu": load_per_cpu,
                "used_percent": round(max(0.0, min(100.0, load_per_cpu * 100)), 1),
            },
            "memory": {
                "total": memory_total,
                "used": memory_used,
                "available": memory_available,
                "used_percent": round((memory_used / memory_total) * 100, 1) if memory_total else 0.0,
                "swap_total": 0,
                "swap_used": 0,
            },
            "disks": self.collect_disk_snapshots(),
            "services": services,
            "processes": [],
            "schedulable": bool(resource_snapshot.get("schedulable")),
            "controller_reachable": bool(resource_snapshot.get("controller_reachable", True)),
        }

    def reconcile_unit(
        self,
        unit: str,
        *,
        has_placement: bool,
        desired_owner: str | None,
        status_before: dict[str, Any],
    ) -> dict[str, Any]:
        # Start or stop one managed unit so local state matches desired ownership.
        load_state = str(status_before.get("load_state", "unknown"))
        active_state = str(status_before.get("active_state", "unknown"))
        active_local = load_state == "loaded" and active_state in ACTIVE_STATES
        desired_local = has_placement and desired_owner == self.hostname

        if not has_placement:
            return {
                "action": "noop",
                "reason": "placement_missing",
                "success": True,
                "desired_local": False,
            }

        if not desired_owner:
            return {
                "action": "noop",
                "reason": "desired_owner_missing",
                "success": True,
                "desired_local": False,
            }

        if load_state != "loaded":
            if desired_local:
                self.logger.warning(
                    "scheduler_managed_unit_missing host=%s unit=%s desired_owner=%s",
                    self.hostname,
                    unit,
                    desired_owner or "",
                )
            return {
                "action": "missing",
                "reason": "unit_not_loaded",
                "success": not desired_local,
                "desired_local": desired_local,
            }

        if desired_local == active_local:
            return {
                "action": "noop",
                "reason": "already_desired_state",
                "success": True,
                "desired_local": desired_local,
            }

        verb = "start" if desired_local else "stop"
        if self.config.ha.scheduler.reconciler_dry_run:
            self.logger.info(
                "scheduler_reconcile_dry_run host=%s unit=%s action=%s desired_owner=%s",
                self.hostname,
                unit,
                verb,
                desired_owner or "",
            )
            return {
                "action": f"would-{verb}",
                "reason": "dry_run",
                "success": True,
                "desired_local": desired_local,
            }

        result = self.run_command(["sudo", "systemctl", "--no-block", verb, unit])
        if result.returncode != 0:
            self.logger.warning(
                "scheduler_reconcile_failed host=%s unit=%s action=%s desired_owner=%s error=%s",
                self.hostname,
                unit,
                verb,
                desired_owner or "",
                result.stderr.strip() or result.stdout.strip() or f"exit_{result.returncode}",
            )
        else:
            self.logger.info(
                "scheduler_reconcile_applied host=%s unit=%s action=%s desired_owner=%s",
                self.hostname,
                unit,
                verb,
                desired_owner or "",
            )
        return {
            "action": verb,
            "reason": "applied" if result.returncode == 0 else "command_failed",
            "success": result.returncode == 0,
            "desired_local": desired_local,
        }

    def build_metric_lines(self, resource_snapshot: dict[str, Any], units: dict[str, dict[str, Any]], now: int) -> str:
        # Render Prometheus metrics for scheduler resource and unit state.
        lines = [
            "# HELP nix_cluster_scheduler_node_schedulable Whether this node currently meets the minimum scheduler capacity thresholds.",
            "# TYPE nix_cluster_scheduler_node_schedulable gauge",
            f'nix_cluster_scheduler_node_schedulable{{host="{self.hostname}"}} {1 if resource_snapshot.get("schedulable") else 0}',
            "# HELP nix_cluster_scheduler_node_memory_available_bytes Available memory published for scheduler placement.",
            "# TYPE nix_cluster_scheduler_node_memory_available_bytes gauge",
            f'nix_cluster_scheduler_node_memory_available_bytes{{host="{self.hostname}"}} {_safe_int(resource_snapshot.get("memory_available_bytes"))}',
            "# HELP nix_cluster_scheduler_node_state_free_bytes Free bytes on the scheduler state volume.",
            "# TYPE nix_cluster_scheduler_node_state_free_bytes gauge",
            f'nix_cluster_scheduler_node_state_free_bytes{{host="{self.hostname}",path="{str(resource_snapshot.get("state_dir_path", "/")).replace('"', '\\"')}"}} {_safe_int(resource_snapshot.get("state_dir_free_bytes"))}',
            "# HELP nix_cluster_scheduler_node_load_per_cpu One-minute load average normalized by CPU count.",
            "# TYPE nix_cluster_scheduler_node_load_per_cpu gauge",
            f'nix_cluster_scheduler_node_load_per_cpu{{host="{self.hostname}"}} {_safe_float(resource_snapshot.get("load_1_per_cpu"))}',
            "# HELP nix_cluster_scheduler_controller_reachable Whether the last controller heartbeat check succeeded on this node.",
            "# TYPE nix_cluster_scheduler_controller_reachable gauge",
            f'nix_cluster_scheduler_controller_reachable{{host="{self.hostname}"}} {1 if resource_snapshot.get("controller_reachable") else 0}',
            "# HELP nix_cluster_scheduler_state_storage_healthy Whether state storage passed all configured checks and recovery observations.",
            "# TYPE nix_cluster_scheduler_state_storage_healthy gauge",
            f'nix_cluster_scheduler_state_storage_healthy{{host="{self.hostname}",state="{resource_snapshot.get("state_storage_health", "unknown")}"}} {1 if resource_snapshot.get("state_storage_healthy") else 0}',
            "# HELP nix_cluster_scheduler_state_storage_healthy_observations Consecutive successful state-storage observations.",
            "# TYPE nix_cluster_scheduler_state_storage_healthy_observations gauge",
            f'nix_cluster_scheduler_state_storage_healthy_observations{{host="{self.hostname}"}} {_safe_int(resource_snapshot.get("state_storage_healthy_observations"))}',
        ]
        if units:
            lines.extend([
                "# HELP nix_cluster_scheduler_unit_assigned_to_local Whether the scheduler currently assigns a managed unit to this node.",
                "# TYPE nix_cluster_scheduler_unit_assigned_to_local gauge",
                "# HELP nix_cluster_scheduler_unit_active_local Whether a managed unit is active on this node after reconciliation.",
                "# TYPE nix_cluster_scheduler_unit_active_local gauge",
            ])
            action_header_added = False
            for unit, payload in sorted(units.items()):
                unit_label = unit.replace('"', '\\"')
                desired_owner = str(payload.get("desired_owner") or "").replace('"', '\\"')
                lines.append(
                    f'nix_cluster_scheduler_unit_assigned_to_local{{host="{self.hostname}",service="{unit_label}",desired_owner="{desired_owner}"}} {1 if payload.get("desired_local") else 0}'
                )
                lines.append(
                    f'nix_cluster_scheduler_unit_active_local{{host="{self.hostname}",service="{unit_label}"}} {1 if payload.get("active_local") else 0}'
                )
                with self.lease_lock:
                    lease = dict(self.owned_leases.get(unit, {}))
                if lease:
                    lines.extend([
                        f'nix_cluster_ownership_lease_valid{{host="{self.hostname}",service="{unit_label}"}} {1 if time.monotonic() < float(lease.get("deadline", 0.0)) else 0}',
                        f'nix_cluster_ownership_lease_seconds_remaining{{host="{self.hostname}",service="{unit_label}"}} {max(0.0, float(lease.get("deadline", 0.0)) - time.monotonic()):.3f}',
                        f'nix_cluster_ownership_lease_renewal_age_seconds{{host="{self.hostname}",service="{unit_label}"}} {max(0, now - _safe_int(lease.get("last_renewed_at"), now))}',
                        f'nix_cluster_ownership_lease_transient_failures{{host="{self.hostname}",service="{unit_label}"}} {self.lease_transient_failures.get(unit, 0)}',
                    ])
                if payload.get("last_action"):
                    if not action_header_added:
                        lines.extend([
                            "# HELP nix_cluster_scheduler_unit_last_action_success Whether the most recent reconciliation action succeeded.",
                            "# TYPE nix_cluster_scheduler_unit_last_action_success gauge",
                        ])
                        action_header_added = True
                    action = str(payload.get("last_action", "")).replace('"', '\\"')
                    lines.append(
                        f'nix_cluster_scheduler_unit_last_action_success{{host="{self.hostname}",service="{unit_label}",action="{action}"}} {1 if payload.get("last_action_success") else 0}'
                    )
        lines.extend([
            "# HELP nix_cluster_scheduler_reconcile_timestamp_seconds Unix timestamp of the most recent scheduler reconciler pass.",
            "# TYPE nix_cluster_scheduler_reconcile_timestamp_seconds gauge",
            f'nix_cluster_scheduler_reconcile_timestamp_seconds{{host="{self.hostname}"}} {now}',
        ])
        return "\n".join(lines) + "\n"

    def run(self) -> None:
        # Main worker loop: publish resources, read placements, reconcile units.
        if not (self.config.ha.enable and self.config.ha.scheduler.enable and self.config.ha.scheduler.reconciler_enable):
            self.logger.info("scheduler reconciler disabled")
            return
        if self.config.ha.runtime_store.type != "etcd" or not self.config.ha.runtime_store.endpoint:
            self.logger.info("scheduler reconciler requires an etcd runtime store endpoint")
            return

        endpoint = self.config.ha.runtime_store.endpoint
        etcd = EtcdClient(endpoint)
        interval = max(15, self.config.ha.scheduler.reconciler_interval_seconds)
        resource_interval = max(15, self.config.ha.scheduler.resource_interval_seconds)
        managed_units = sorted(set(self.config.ha.scheduler.managed_units))
        placement_prefix = self.config.ha.scheduler.placement_prefix.rstrip("/")
        ownership_prefix = self.config.ha.scheduler.ownership_prefix.rstrip("/")
        request_prefix = self.config.ha.scheduler.request_prefix.rstrip("/")
        resource_prefix = self.config.ha.scheduler.resource_prefix.rstrip("/")
        node_detail_prefix = NODE_DETAIL_PREFIX.rstrip("/")
        reconcile_state_path = Path(self.config.directories.state) / "ha" / "scheduler-reconciler.json"
        resource_state_path = Path(self.config.directories.state) / "ha" / "scheduler-resources.json"
        metrics_path = Path(self.config.directories.metrics) / "scheduler-reconciler.prom"
        write_backoff_until = 0.0
        next_resource_publish_at = 0.0
        last_resource_snapshot: dict[str, Any] | None = None

        if self.config.ha.scheduler.rejected_managed_units:
            self.logger.warning(
                "scheduler_rejected_unsafe_units host=%s units=%s",
                self.hostname,
                ",".join(sorted(self.config.ha.scheduler.rejected_managed_units)),
            )
        if reconcile_state_path.exists():
            try:
                previous_state = json.loads(reconcile_state_path.read_text(encoding="utf-8"))
                previous_units = set(dict(previous_state.get("managed_units", {})).keys())
                removed_units = sorted(previous_units - set(managed_units))
                for unit in removed_units:
                    status = self.collect_unit_status(unit, int(time.time()))
                    if status.get("active_state") in ACTIVE_STATES:
                        self.logger.info("scheduler_removed_workload_stop host=%s unit=%s", self.hostname, unit)
                        self.run_command(["sudo", "systemctl", "--no-block", "stop", unit])
                    if ownership_prefix:
                        self.release_service_lease(etcd, f"{ownership_prefix}/{unit}", unit)
            except Exception as error:
                self.logger.warning("scheduler_removed_workload_cleanup_failed host=%s error=%s", self.hostname, error)

        threading.Thread(target=self.lease_keeper, args=(endpoint,), daemon=True, name="nix-cluster-lease-keeper").start()
        self.logger.info("starting scheduler reconciler on %s", self.hostname)
        while True:
            try:
                now = int(time.time())
                if last_resource_snapshot is None or time.monotonic() >= next_resource_publish_at:
                    last_resource_snapshot = self.collect_resource_snapshot(now)
                    atomic_write_json(resource_state_path, last_resource_snapshot)
                    if resource_prefix and time.monotonic() >= write_backoff_until:
                        try:
                            etcd.put_json(f"{resource_prefix}/{self.hostname}", last_resource_snapshot)
                        except RuntimeStoreRateLimited as error:
                            event, retry_after = _runtime_store_warning_details(error, max(5.0, float(interval)))
                            write_backoff_until = time.monotonic() + retry_after
                            self.log_runtime_store_warning(
                                endpoint,
                                "%s endpoint=%s path=%s retry_after=%.1fs",
                                event,
                                endpoint,
                                f"{resource_prefix}/{self.hostname}",
                                retry_after,
                            )
                    next_resource_publish_at = time.monotonic() + resource_interval

                placement_records = etcd.get_prefix(placement_prefix) if placement_prefix else {}
                units: dict[str, dict[str, Any]] = {}
                for unit in managed_units:
                    placement_key = f"{placement_prefix}/{unit}"
                    placement_payload = placement_records.get(placement_key)
                    has_placement = placement_payload is not None
                    desired_owner = str(placement_payload.get("desired_owner") or "") if placement_payload else ""
                    if self.previous_assignments.get(unit) != (desired_owner or None):
                        self.logger.info(
                            "scheduler_assignment_change host=%s unit=%s previous=%s current=%s",
                            self.hostname,
                            unit,
                            self.previous_assignments.get(unit) or "",
                            desired_owner,
                        )
                    status_before = self.collect_unit_status(unit, now)
                    generation = max(1, _safe_int(placement_payload.get("generation"), 1)) if placement_payload else 1
                    ownership_key = f"{ownership_prefix}/{unit}"
                    desired_local = has_placement and desired_owner == self.hostname
                    local_health_allows = bool(
                        last_resource_snapshot.get("node_schedulable_configured", True)
                        and last_resource_snapshot.get("state_storage_healthy", True)
                    )
                    lease_held = False
                    lease_enforced = self.config.ha.scheduler.ownership_lease_enable
                    if desired_local and not local_health_allows:
                        if status_before.get("active_state") in ACTIVE_STATES:
                            self.run_command(["sudo", "systemctl", "--no-block", "stop", unit])
                        action = {
                            "action": "stop",
                            "reason": "local_node_or_storage_quarantined",
                            "success": True,
                            "desired_local": False,
                        }
                    elif desired_local and lease_enforced:
                        lease_held = self.ensure_service_lease(etcd, ownership_key, unit, generation, now)
                        if lease_held:
                            action = self.reconcile_unit(
                                unit,
                                has_placement=has_placement,
                                desired_owner=desired_owner or None,
                                status_before=status_before,
                            )
                        else:
                            if status_before.get("active_state") in ACTIVE_STATES:
                                self.run_command(["sudo", "systemctl", "--no-block", "stop", unit])
                            action = {"action": "wait-for-lease", "reason": "ownership_lease_unavailable", "success": True, "desired_local": True}
                    else:
                        action = self.reconcile_unit(
                            unit,
                            has_placement=has_placement,
                            desired_owner=desired_owner or None,
                            status_before=status_before,
                        )
                    status_after = self.collect_unit_status(unit, now)
                    active_local = status_after.get("load_state") == "loaded" and status_after.get("active_state") in ACTIVE_STATES
                    if lease_enforced and (not desired_local or not local_health_allows) and not active_local:
                        self.release_service_lease(etcd, ownership_key, unit)
                    units[unit] = {
                        "desired_owner": desired_owner or None,
                        "desired_local": bool(action.get("desired_local")),
                        "active_local": active_local,
                        "has_placement": has_placement,
                        "placement_key": placement_key,
                        "placement_updated_at": _safe_int(placement_payload.get("updated_at")) if placement_payload else 0,
                        "placement_generation": generation,
                        "ownership_lease_held": lease_held,
                        "last_action": action.get("action"),
                        "last_action_reason": action.get("reason"),
                        "last_action_success": bool(action.get("success")),
                        "status_before": status_before,
                        "status_after": status_after,
                    }
                    self.previous_assignments[unit] = desired_owner or None

                reconcile_state = {
                    "host": self.hostname,
                    "observed_at": now,
                    "placement_prefix": placement_prefix,
                    "resource_prefix": resource_prefix,
                    "resource": last_resource_snapshot,
                    "managed_units": units,
                }
                node_detail = self.build_node_detail(last_resource_snapshot, units, now)
                atomic_write_json(reconcile_state_path, reconcile_state)
                atomic_write_text(metrics_path, self.build_metric_lines(last_resource_snapshot, units, now))
                if node_detail_prefix and time.monotonic() >= write_backoff_until:
                    try:
                        etcd.put_json(f"{node_detail_prefix}/{self.hostname}", node_detail)
                    except RuntimeStoreRateLimited as error:
                        event, retry_after = _runtime_store_warning_details(error, max(5.0, float(interval)))
                        write_backoff_until = time.monotonic() + retry_after
                        self.log_runtime_store_warning(
                            endpoint,
                            "%s endpoint=%s path=%s retry_after=%.1fs",
                            event,
                            endpoint,
                            f"{node_detail_prefix}/{self.hostname}",
                            retry_after,
                        )
            except RuntimeStoreRateLimited as error:
                self.stop_expired_leases(type(error).__name__)
                event, retry_after = _runtime_store_warning_details(error, max(5.0, float(interval)))
                write_backoff_until = time.monotonic() + retry_after
                self.log_runtime_store_warning(
                    endpoint,
                    "%s endpoint=%s retry_after=%.1fs",
                    event,
                    endpoint,
                    retry_after,
                )
            except urllib.error.URLError as error:
                self.stop_expired_leases(type(error).__name__)
                self.log_runtime_store_warning(
                    endpoint,
                    "runtime_store_unreachable endpoint=%s error=%s",
                    endpoint,
                    error,
                )
            except Exception as error:
                self.stop_expired_leases(type(error).__name__)
                self.logger.exception("reconciler_loop_failed: %s", error)
            time.sleep(interval)


# Controller-side scheduler that turns health reports into placement records.
class ClusterMonitor:
    def __init__(self, config_path: str | None = None):
        # Load scheduler config and initialize leadership/target change tracking.
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-monitor")
        self.controller = socket.gethostname()
        self.current_leader_lease_id = 0
        self.previous_targets: dict[str, str | None] = {}
        self.previous_unavailable_signatures: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {}
        self.previous_unavailable_logged_at: dict[str, float] = {}
        self.previous_leader_host: str | None = None
        self.previous_is_leader: bool | None = None
        self.last_runtime_store_warning: tuple[str, str] | None = None
        self.last_runtime_store_warning_at = 0.0

    def log_runtime_store_warning(self, endpoint: str, message: str, *args: Any) -> None:
        # Log repeated etcd warnings at a slower pace so journals stay readable.
        rendered = message % args if args else message
        signature = (endpoint, rendered)
        now = time.monotonic()
        if signature == self.last_runtime_store_warning and (now - self.last_runtime_store_warning_at) < REPEATED_WARNING_INTERVAL_SECONDS:
            return
        self.last_runtime_store_warning = signature
        self.last_runtime_store_warning_at = now
        self.logger.warning(message, *args)

    def should_log_service_unavailable(self, service: str, unhealthy_nodes: list[str], stale_nodes: list[str]) -> bool:
        # Throttle identical service-unavailable warnings.
        signature = (tuple(unhealthy_nodes), tuple(stale_nodes))
        now = time.monotonic()
        previous_signature = self.previous_unavailable_signatures.get(service)
        previous_logged_at = self.previous_unavailable_logged_at.get(service, 0.0)
        if previous_signature == signature and (now - previous_logged_at) < REPEATED_WARNING_INTERVAL_SECONDS:
            return False
        self.previous_unavailable_signatures[service] = signature
        self.previous_unavailable_logged_at[service] = now
        return True

    @staticmethod
    def service_and_host_from_key(prefix: str, key: str) -> tuple[str, str]:
        # Split `/prefix/host/unit` health keys back into host and unit names.
        trimmed = key.removeprefix(prefix.rstrip("/") + "/")
        host, _, unit = trimmed.partition("/")
        return host, unit

    @staticmethod
    def host_from_resource_key(prefix: str, key: str) -> str:
        # Split `/prefix/host` resource keys back into host names.
        return key.removeprefix(prefix.rstrip("/") + "/")

    @staticmethod
    def stale_runtime_keys(
        managed_units: set[str],
        placement_prefix: str,
        placement_records: dict[str, Any],
        request_prefix: str,
        request_records: dict[str, Any],
        ownership_prefix: str,
        ownership_records: dict[str, Any],
    ) -> list[str]:
        stale: list[str] = []
        if placement_prefix:
            stale.extend(
                key for key in placement_records
                if key.removeprefix(placement_prefix + "/") not in managed_units
            )
        if request_prefix:
            stale.extend(
                key for key in request_records
                if key.removeprefix(request_prefix + "/") not in managed_units
            )
        if ownership_prefix:
            stale.extend(
                key for key in ownership_records
                if key.removeprefix(ownership_prefix + "/") not in managed_units
            )
        return sorted(set(stale))

    def build_leader_payload(self, now: int, lease_id: int = 0) -> dict[str, Any]:
        # Create the scheduler leadership record written to etcd.
        scheduler_cfg = self.config.ha.scheduler
        payload: dict[str, Any] = {
            "hostname": self.controller,
            "controller_mode": scheduler_cfg.controller_mode,
            "observed_at": now,
            "lease_ttl_seconds": scheduler_cfg.lease_ttl_seconds if scheduler_cfg.controller_mode == "elected" else 0,
        }
        if lease_id:
            payload["lease_id"] = lease_id
        return payload

    def resolve_fixed_leader_host(self) -> str:
        # Return the configured fixed scheduler leader, defaulting to this host.
        fixed_host = self.config.ha.scheduler.fixed_controller_host.strip()
        if fixed_host:
            return fixed_host
        return self.controller

    def note_leadership_state(self, is_leader: bool, leader_payload: dict[str, Any]) -> None:
        # Log leadership changes without repeating the same state every loop.
        leader_host = str(leader_payload.get("hostname", "") or "")
        if leader_host != self.previous_leader_host or is_leader != self.previous_is_leader:
            self.logger.info(
                "scheduler_leadership_state host=%s leader=%s is_leader=%s mode=%s",
                self.controller,
                leader_host,
                str(is_leader).lower(),
                self.config.ha.scheduler.controller_mode,
            )
            self.previous_leader_host = leader_host
            self.previous_is_leader = is_leader

    def ensure_scheduler_leadership(self, etcd: EtcdClient, now: int) -> tuple[bool, dict[str, Any]]:
        # Decide whether this controller may publish placement decisions.
        scheduler_cfg = self.config.ha.scheduler
        leader_key = scheduler_cfg.leader_key

        if scheduler_cfg.controller_mode == "fixed":
            fixed_leader = self.resolve_fixed_leader_host()
            leader_payload = {
                "hostname": fixed_leader,
                "controller_mode": "fixed",
                "observed_at": now,
                "lease_ttl_seconds": 0,
            }
            is_leader = fixed_leader == self.controller
            if is_leader:
                try:
                    etcd.put_json(leader_key, leader_payload)
                except RuntimeStoreRateLimited as error:
                    event, retry_after = _runtime_store_warning_details(
                        error,
                        max(5.0, float(self.config.ha.scheduler.interval_seconds)),
                    )
                    self.log_runtime_store_warning(
                        self.config.ha.runtime_store.endpoint,
                        "%s endpoint=%s path=%s retry_after=%.1fs",
                        event,
                        self.config.ha.runtime_store.endpoint,
                        leader_key,
                        retry_after,
                    )
            self.current_leader_lease_id = 0
            self.note_leadership_state(is_leader, leader_payload)
            return is_leader, leader_payload

        desired_ttl = max(1, scheduler_cfg.lease_ttl_seconds)
        old_lease_id = self.current_leader_lease_id
        new_lease_id = etcd.grant_lease(desired_ttl)
        if not new_lease_id:
            raise RuntimeError("scheduler leadership lease grant returned an empty lease id")

        leader_payload = self.build_leader_payload(now, lease_id=new_lease_id)

        if old_lease_id:
            if etcd.replace_json_if_lease(leader_key, old_lease_id, leader_payload, lease_id=new_lease_id):
                if old_lease_id != new_lease_id:
                    etcd.revoke_lease(old_lease_id)
                self.current_leader_lease_id = new_lease_id
                self.note_leadership_state(True, leader_payload)
                return True, leader_payload
            etcd.revoke_lease(new_lease_id)
            self.current_leader_lease_id = 0

        fresh_lease_id = etcd.grant_lease(desired_ttl)
        if not fresh_lease_id:
            raise RuntimeError("scheduler leadership acquisition could not allocate a lease id")

        leader_payload = self.build_leader_payload(now, lease_id=fresh_lease_id)
        if etcd.put_json_if_absent(leader_key, leader_payload, lease_id=fresh_lease_id):
            self.current_leader_lease_id = fresh_lease_id
            self.note_leadership_state(True, leader_payload)
            return True, leader_payload

        etcd.revoke_lease(fresh_lease_id)
        observed_leader = etcd.get_key(leader_key)
        leader_payload = observed_leader["value"] if observed_leader and isinstance(observed_leader.get("value"), dict) else {
            "hostname": "",
            "controller_mode": "elected",
            "observed_at": now,
            "lease_ttl_seconds": desired_ttl,
        }
        self.note_leadership_state(False, leader_payload)
        return False, leader_payload

    def resource_record_is_fresh(self, payload: dict[str, Any] | None, now: int, stale_after: int) -> bool:
        # Return true when a node resource snapshot is recent enough to trust.
        if not payload:
            return False
        return (now - _safe_int(payload.get("observed_at"))) <= stale_after

    def resource_record_is_schedulable(self, payload: dict[str, Any] | None, now: int, stale_after: int) -> bool:
        # Return true when a fresh resource snapshot says the node can take work.
        if not self.resource_record_is_fresh(payload, now, stale_after):
            return False
        return bool(payload.get("schedulable", True))

    def resource_record_meets_policy(self, service: str, payload: dict[str, Any] | None, now: int, stale_after: int) -> bool:
        if not self.resource_record_is_schedulable(payload, now, stale_after):
            return False
        policy = getattr(self.config.ha.scheduler, "unit_policies", {}).get(service)
        if not policy or not payload:
            return True
        if policy.minimum_memory_available_bytes and _safe_int(payload.get("memory_available_bytes")) < policy.minimum_memory_available_bytes:
            return False
        if policy.maximum_load_per_cpu and _safe_float(payload.get("load_1_per_cpu"), 9999.0) > policy.maximum_load_per_cpu:
            return False
        if policy.require_healthy_state_storage and payload.get("state_storage_healthy") is not True:
            return False
        return True

    def rank_nodes_by_resources(
        self,
        candidate_nodes: list[str],
        resource_records: dict[str, dict[str, Any]],
        *,
        service: str = "",
        reports: dict[str, dict[str, Any]] | None = None,
        now: int,
        stale_after: int,
    ) -> list[str]:
        policy = getattr(self.config.ha.scheduler, "unit_policies", {}).get(service)
        preferred = policy.preferred_nodes if policy else []

        def resource_sort_key(host: str) -> tuple[int, int, int, int, int, int, float, str]:
            # Build the tuple Python uses to sort best scheduler targets first.
            payload = resource_records.get(host)
            report = reports.get(host, {}) if reports else {}
            report_load_state = str(report.get("load_state", "unknown"))
            report_active_state = str(report.get("active_state", "unknown"))
            if bool(report.get("healthy")):
                service_state_rank = 0
            elif report_load_state == "loaded" and report_active_state not in ACTIVE_STATES:
                service_state_rank = 1
            else:
                service_state_rank = 2
            if not self.resource_record_is_fresh(payload, now, stale_after):
                return (service_state_rank, 1, 1, len(preferred) + 1, 0, 0, 9999.0, host)
            return (
                service_state_rank,
                0 if self.resource_record_meets_policy(service, payload, now, stale_after) else 1,
                0 if bool(payload.get("controller_reachable", True)) else 1,
                preferred.index(host) if host in preferred else len(preferred),
                -_safe_int(payload.get("memory_available_bytes")),
                -_safe_int(payload.get("state_dir_free_bytes")),
                _safe_float(payload.get("load_1_per_cpu"), 9999.0),
                host,
            )

        return sorted(candidate_nodes, key=resource_sort_key)

    def choose_desired_owner(
        self,
        service: str,
        candidate_nodes: list[str],
        healthy_nodes: list[str],
        resource_records: dict[str, dict[str, Any]],
        *,
        reports: dict[str, dict[str, Any]] | None = None,
        current_owner: str | None = None,
        now: int,
        stale_after: int,
    ) -> str | None:
        # Pick which node should own a service for the next scheduler interval.
        if not candidate_nodes:
            return None
        strategy = self.config.ha.scheduler.default_strategy
        prior = current_owner or self.previous_targets.get(service)
        ranked_nodes = self.rank_nodes_by_resources(candidate_nodes, resource_records, service=service, reports=reports, now=now, stale_after=stale_after)
        schedulable_nodes = [
            host for host in ranked_nodes
            if self.resource_record_meets_policy(service, resource_records.get(host), now, stale_after)
        ]

        if strategy == "prefer-current-healthy" and prior in healthy_nodes:
            if self.resource_record_meets_policy(service, resource_records.get(prior), now, stale_after):
                return prior

        if schedulable_nodes:
            if prior and prior not in healthy_nodes:
                next_nodes = [host for host in schedulable_nodes if host != prior]
                if next_nodes:
                    return next_nodes[0]
            return schedulable_nodes[0]
        return prior

    def advance_placement(
        self,
        service: str,
        current: dict[str, Any],
        candidate_nodes: list[str],
        healthy_nodes: list[str],
        ranked_nodes: list[str],
        reports: dict[str, dict[str, Any]],
        ownership: dict[str, Any] | None,
        now: int,
        stale_after: int,
        resource_records: dict[str, dict[str, Any]] | None = None,
        requested_target: str | None = None,
    ) -> dict[str, Any]:
        """Advance one fail-closed, hysteretic placement state machine."""
        cfg = self.config.ha.scheduler
        desired = str(current.get("desired_owner") or "") or None
        active = str(current.get("active_owner") or desired or "") or None
        target = str(current.get("target_owner") or "") or None
        phase = str(current.get("phase") or "stable")
        generation = max(1, _safe_int(current.get("generation"), 1))
        failures = max(0, _safe_int(current.get("failure_count")))
        rebalance_observations = max(0, _safe_int(current.get("rebalance_observations")))
        successes = max(0, _safe_int(current.get("success_count")))
        stable_since = _safe_int(current.get("stable_since"), _safe_int(current.get("updated_at"), now))
        phase_started_at = _safe_int(current.get("phase_started_at"), now)
        cooldowns = {str(host): _safe_int(until) for host, until in dict(current.get("cooldowns", {})).items() if _safe_int(until) > now}

        def fresh(host: str | None) -> bool:
            report = reports.get(host or "", {})
            return bool(report) and now - _safe_int(report.get("observed_at")) <= stale_after

        owner_host = str((ownership or {}).get("host") or "") or None
        owner_generation = _safe_int((ownership or {}).get("generation"))
        lease_matches_active = bool(active and owner_host == active and owner_generation == generation)
        lease_matches_target = bool(target and owner_host == target and owner_generation == generation)

        def has_matching_lease(host: str | None) -> bool:
            if not cfg.ownership_lease_enable:
                return bool(host)
            return bool(host and owner_host == host and owner_generation == generation)

        def healthy(host: str | None) -> bool:
            return fresh(host) and bool(reports.get(host or "", {}).get("healthy")) and has_matching_lease(host)

        eligible = [
            host for host in ranked_nodes
            if host not in cooldowns
            and (
                not resource_records
                or self.resource_record_meets_policy(service, resource_records.get(host), now, stale_after)
            )
        ]
        if not desired:
            chosen = requested_target if requested_target in eligible else next(iter(eligible), None)
            desired = chosen
            target = chosen
            active = None
            phase = "activating" if chosen else "stable"
            phase_started_at = now
            stable_since = now

        if phase == "stable" and active:
            active_resource = (resource_records or {}).get(active, {})
            confirmed_node_quarantine = bool(
                self.resource_record_is_fresh(active_resource, now, stale_after)
                and (
                    active_resource.get("node_schedulable_configured") is False
                    or active_resource.get("state_storage_healthy") is False
                )
            )
            if confirmed_node_quarantine and active not in eligible:
                alternatives = [host for host in eligible if host != active]
                target = next(iter(alternatives), None)
                desired = target
                generation += 1
                phase = "deactivating" if target else "awaiting-fence"
                phase_started_at = now
                failures = 0
                successes = 0
            elif requested_target and requested_target in eligible and requested_target != active:
                target = requested_target
                desired = target
                generation += 1
                phase = "deactivating"
                phase_started_at = now
                failures = 0
                successes = 0
            elif cfg.ownership_lease_enable and not lease_matches_active:
                failures += 1
                alternatives = [host for host in eligible if host != active]
                if failures >= max(1, cfg.failure_threshold) and alternatives:
                    target = alternatives[0]
                    desired = target
                    generation += 1
                    phase = "deactivating"
                    phase_started_at = now
                    successes = 0
                else:
                    phase = "recovering"
                    phase_started_at = now
            elif healthy(active):
                failures = 0
            elif fresh(active):
                failures += 1
            # Unknown telemetry with a live ownership lease is not failure.
            if failures >= max(1, cfg.failure_threshold):
                alternatives = [host for host in eligible if host != active]
                if alternatives:
                    target = alternatives[0]
                    desired = target
                    generation += 1
                    phase = "deactivating"
                    phase_started_at = now
                    successes = 0
            policy = getattr(cfg, "unit_policies", {}).get(service)
            if (
                policy
                and policy.automatic_rebalance
                and active not in eligible
                and healthy(active)
                and now - stable_since >= max(1, cfg.minimum_owner_seconds)
            ):
                rebalance_observations += 1
                alternatives = [host for host in eligible if host != active]
                if resource_records and alternatives:
                    active_resource = resource_records.get(active, {})
                    qualified: list[str] = []
                    for host in alternatives:
                        target_resource = resource_records.get(host, {})
                        memory_advantage = _safe_int(target_resource.get("memory_available_bytes")) - _safe_int(active_resource.get("memory_available_bytes"))
                        active_load = _safe_float(active_resource.get("load_1_per_cpu"))
                        target_load = _safe_float(target_resource.get("load_1_per_cpu"))
                        load_advantage = ((active_load - target_load) / active_load * 100.0) if active_load > 0 else 0.0
                        if memory_advantage >= policy.minimum_memory_advantage_bytes or load_advantage >= policy.minimum_load_advantage_percent:
                            qualified.append(host)
                    alternatives = qualified
                if rebalance_observations >= max(1, policy.rebalance_observation_threshold) and alternatives:
                    target = alternatives[0]
                    desired = target
                    generation += 1
                    phase = "deactivating"
                    phase_started_at = now
                    successes = 0
                    rebalance_observations = 0
            else:
                rebalance_observations = 0

        elif phase != "stable":
            if phase == "recovering" and active:
                if healthy(active) and (lease_matches_active or not cfg.ownership_lease_enable):
                    phase = "stable"
                    stable_since = now
                    phase_started_at = now
                    failures = 0
                    successes = 0
                else:
                    failures += 1
                    alternatives = [host for host in eligible if host != active]
                    if failures >= max(1, cfg.failure_threshold) and alternatives:
                        target = alternatives[0]
                        desired = target
                        generation += 1
                        phase = "deactivating"
                        phase_started_at = now
                        successes = 0
                    else:
                        target = None
                        desired = active
            elif lease_matches_target and target:
                phase = "verifying" if healthy(target) else "activating"
                if healthy(target):
                    successes += 1
                    if successes >= max(1, cfg.recovery_threshold):
                        active = target
                        desired = target
                        target = None
                        phase = "stable"
                        stable_since = now
                        phase_started_at = now
                        failures = 0
                        successes = 0
                else:
                    successes = 0
            elif target and now - phase_started_at > max(1, cfg.transition_timeout_seconds):
                cooldowns[target] = now + max(1, cfg.target_cooldown_seconds)
                alternatives = [host for host in eligible if host not in {target, active}]
                if alternatives:
                    target = alternatives[0]
                    desired = target
                    generation += 1
                    phase = "deactivating"
                    phase_started_at = now
                    successes = 0
                else:
                    phase = "awaiting-fence"
            elif cfg.ownership_lease_enable and owner_host and not lease_matches_target:
                phase = "awaiting-fence"
            elif target:
                phase = "verifying" if lease_matches_target and healthy(target) else "activating"
                if healthy(target) and (lease_matches_target or not cfg.ownership_lease_enable):
                    successes += 1
                    if successes >= max(1, cfg.recovery_threshold):
                        active = target
                        desired = target
                        target = None
                        phase = "stable"
                        stable_since = now
                        phase_started_at = now
                        failures = 0
                        successes = 0
                else:
                    successes = 0

        return {
            "desired_owner": desired,
            "active_owner": active,
            "target_owner": target,
            "generation": generation,
            "phase": phase,
            "phase_started_at": phase_started_at,
            "stable_since": stable_since,
            "failure_count": failures,
            "rebalance_observations": rebalance_observations,
            "success_count": successes,
            "cooldowns": cooldowns,
            "ownership_host": owner_host,
            "ownership_generation": owner_generation,
        }

    def move_request_target(
        self,
        service: str,
        request: dict[str, Any] | None,
        candidate_nodes: list[str],
        now: int,
    ) -> tuple[str | None, dict[str, Any] | None]:
        if not request or request.get("status") != "pending":
            return None, None
        target = str(request.get("target_owner") or "") or None
        if _safe_int(request.get("expires_at")) <= now:
            failed = dict(request)
            failed.update({"status": "expired", "completed_at": now, "failure": "request expired"})
            return None, failed
        if not target:
            failed = dict(request)
            failed.update({"status": "failed", "completed_at": now, "failure": "missing target_owner"})
            return None, failed
        if target not in candidate_nodes:
            failed = dict(request)
            failed.update({"status": "failed", "completed_at": now, "failure": f"target does not report unit {service}"})
            return None, failed
        return target, None

    def update_move_request(
        self,
        request: dict[str, Any] | None,
        state: dict[str, Any],
        now: int,
    ) -> dict[str, Any] | None:
        if not request or request.get("status") != "pending":
            return None
        target = str(request.get("target_owner") or "")
        if state.get("phase") == "stable" and state.get("active_owner") == target:
            complete = dict(request)
            complete.update({
                "status": "completed",
                "completed_at": now,
                "expires_at": now + REQUEST_COMPLETE_TTL_SECONDS,
            })
            return complete
        return None

    def build_cluster_metrics(self, cluster_state: dict[str, Any]) -> str:
        # Render Prometheus metrics for the controller's aggregate cluster view.
        lines = [
            "# HELP nix_cluster_service_instances Number of nodes currently reporting a service by health state.",
            "# TYPE nix_cluster_service_instances gauge",
        ]
        for service, payload in sorted(cluster_state.get("services", {}).items()):
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="candidate"}} {len(payload.get("candidate_nodes", []))}')
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="healthy"}} {len(payload.get("healthy_nodes", []))}')
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="unhealthy"}} {len(payload.get("unhealthy_nodes", []))}')
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="stale"}} {len(payload.get("stale_nodes", []))}')
            lines.append(f'nix_cluster_service_usable{{service="{service}"}} {1 if payload.get("usable") else 0}')
            lines.append(f'nix_cluster_service_routable{{service="{service}"}} {1 if payload.get("routable") else 0}')
            lines.append(f'nix_cluster_service_lease_valid{{service="{service}"}} {1 if payload.get("lease_valid") else 0}')
        for host, payload in sorted(cluster_state.get("resources", {}).items()):
            state = str(payload.get("state_storage_health", "unknown"))
            reason = str(payload.get("state_storage_reason", "unknown"))
            lines.append(f'nix_cluster_node_storage_healthy{{host="{host}",state="{state}",reason="{reason}"}} {1 if payload.get("state_storage_healthy") else 0}')
        scheduler = cluster_state.get("scheduler", {})
        leader = scheduler.get("leader", {})
        controller_mode = str(scheduler.get("controller_mode", ""))
        leader_host = str(leader.get("hostname", ""))
        lines.extend([
            "# HELP nix_cluster_scheduler_is_leader Whether this controller is currently publishing scheduler decisions.",
            "# TYPE nix_cluster_scheduler_is_leader gauge",
            f'nix_cluster_scheduler_is_leader{{host="{self.controller}",controller_mode="{controller_mode}"}} {1 if scheduler.get("is_leader") else 0}',
        ])
        if leader_host:
            lines.extend([
                "# HELP nix_cluster_scheduler_leader_info Information about the active scheduler leader.",
                "# TYPE nix_cluster_scheduler_leader_info gauge",
                f'nix_cluster_scheduler_leader_info{{host="{leader_host}",controller_mode="{controller_mode}"}} 1',
            ])
        resources = cluster_state.get("resources", {})
        if resources:
            lines.extend([
                "# HELP nix_cluster_scheduler_node_memory_available_bytes Available memory published for scheduler placement.",
                "# TYPE nix_cluster_scheduler_node_memory_available_bytes gauge",
                "# HELP nix_cluster_scheduler_node_state_free_bytes Free bytes on the scheduler state volume.",
                "# TYPE nix_cluster_scheduler_node_state_free_bytes gauge",
                "# HELP nix_cluster_scheduler_node_schedulable Whether the node currently meets minimum scheduler capacity thresholds.",
                "# TYPE nix_cluster_scheduler_node_schedulable gauge",
                "# HELP nix_cluster_scheduler_node_load_per_cpu One-minute load average normalized by CPU count.",
                "# TYPE nix_cluster_scheduler_node_load_per_cpu gauge",
            ])
            for host, payload in sorted(resources.items()):
                state_dir_path = str(payload.get("state_dir_path", "/")).replace('"', '\\"')
                lines.append(f'nix_cluster_scheduler_node_memory_available_bytes{{host="{host}"}} {_safe_int(payload.get("memory_available_bytes"))}')
                lines.append(
                    f'nix_cluster_scheduler_node_state_free_bytes{{host="{host}",path="{state_dir_path}"}} {_safe_int(payload.get("state_dir_free_bytes"))}'
                )
                lines.append(f'nix_cluster_scheduler_node_schedulable{{host="{host}"}} {1 if payload.get("schedulable") else 0}')
                lines.append(f'nix_cluster_scheduler_node_load_per_cpu{{host="{host}"}} {_safe_float(payload.get("load_1_per_cpu"))}')
        desired_owner_header_added = False
        lines.extend([
            "# HELP nix_cluster_service_report_age_seconds Age of a worker service report.",
            "# TYPE nix_cluster_service_report_age_seconds gauge",
            "# HELP nix_cluster_placement_transition_age_seconds Age of the current placement phase.",
            "# TYPE nix_cluster_placement_transition_age_seconds gauge",
            "# HELP nix_cluster_placement_failures Consecutive confirmed owner failures.",
            "# TYPE nix_cluster_placement_failures gauge",
            "# HELP nix_cluster_placement_phase Current placement state-machine phase.",
            "# TYPE nix_cluster_placement_phase gauge",
        ])
        for service, payload in sorted(cluster_state.get("services", {}).items()):
            escaped_service = service.replace('"', '\\"')
            for host, report in sorted(payload.get("reports", {}).items()):
                escaped_host = host.replace('"', '\\"')
                lines.append(
                    f'nix_cluster_service_report_age_seconds{{service="{escaped_service}",host="{escaped_host}"}} '
                    f'{max(0, int(time.time()) - _safe_int(report.get("observed_at")))}'
                )
            phase = str(payload.get("phase", "legacy")).replace('"', '\\"')
            lines.append(f'nix_cluster_placement_phase{{service="{escaped_service}",phase="{phase}"}} 1')
            lines.append(f'nix_cluster_placement_failures{{service="{escaped_service}"}} {_safe_int(payload.get("failure_count"))}')
            lines.append(
                f'nix_cluster_placement_transition_age_seconds{{service="{escaped_service}"}} '
                f'{max(0, int(time.time()) - _safe_int(payload.get("phase_started_at"), int(time.time())))}'
            )
            desired_owner = payload.get("desired_owner")
            if not desired_owner:
                continue
            if not desired_owner_header_added:
                lines.extend([
                    "# HELP nix_cluster_service_desired_owner Desired owner published by the scheduler for a service.",
                    "# TYPE nix_cluster_service_desired_owner gauge",
                ])
                desired_owner_header_added = True
            lines.append(f'nix_cluster_service_desired_owner{{service="{service}",host="{desired_owner}"}} 1')
        lines.extend([
            "# HELP nix_cluster_monitor_timestamp_seconds Unix timestamp of the most recent controller aggregation pass.",
            "# TYPE nix_cluster_monitor_timestamp_seconds gauge",
            f'nix_cluster_monitor_timestamp_seconds{{host="{self.controller}"}} {int(time.time())}',
        ])
        return "\n".join(lines) + "\n"

    def run(self) -> None:
        # Main controller loop: read health, choose owners, write placements.
        if not self.config.is_controller:
            self.logger.info("monitor disabled on non-controller node")
            return
        if not (self.config.ha.enable and self.config.ha.scheduler.enable):
            self.logger.info("controller scheduler disabled")
            return
        if self.config.ha.runtime_store.type != "etcd" or not self.config.ha.runtime_store.endpoint:
            self.logger.info("controller scheduler requires an etcd runtime store endpoint")
            return

        endpoint = self.config.ha.runtime_store.endpoint
        prefix = self.config.ha.runtime_store.key_prefix
        stale_after = max(1, self.config.ha.runtime_store.stale_after_seconds)
        interval = max(15, self.config.ha.scheduler.interval_seconds)
        resource_prefix = self.config.ha.scheduler.resource_prefix.rstrip("/")
        resource_stale_after = max(stale_after, self.config.ha.scheduler.resource_interval_seconds * 3)
        managed_units = set(_dedupe_preserve_order(self.config.ha.scheduler.managed_units))
        cluster_state_path = Path(self.config.directories.state) / "ha" / "cluster-state.json"
        metrics_path = Path(self.config.directories.metrics) / "cluster-state.prom"
        etcd = EtcdClient(endpoint)
        placement_prefix = self.config.ha.scheduler.placement_prefix.rstrip("/")
        request_prefix = self.config.ha.scheduler.request_prefix.rstrip("/")
        ownership_prefix = self.config.ha.scheduler.ownership_prefix.rstrip("/")
        request_prefix = self.config.ha.scheduler.request_prefix.rstrip("/")
        node_detail_prefix = NODE_DETAIL_PREFIX.rstrip("/")
        write_backoff_until = 0.0

        if self.config.ha.scheduler.rejected_managed_units:
            self.logger.warning(
                "scheduler_rejected_unsafe_units controller=%s units=%s",
                self.controller,
                ",".join(sorted(self.config.ha.scheduler.rejected_managed_units)),
            )

        self.logger.info("starting controller monitor on %s", self.controller)
        while True:
            try:
                now = int(time.time())
                is_leader, leader_payload = self.ensure_scheduler_leadership(etcd, now)
                records = etcd.get_prefix(prefix)
                resource_records: dict[str, dict[str, Any]] = {}
                if resource_prefix:
                    for key, payload in etcd.get_prefix(resource_prefix).items():
                        host = self.host_from_resource_key(resource_prefix, key)
                        if host:
                            resource_records[host] = payload
                node_details: dict[str, dict[str, Any]] = {}
                if node_detail_prefix:
                    for key, payload in etcd.get_prefix(node_detail_prefix).items():
                        host = self.host_from_resource_key(node_detail_prefix, key)
                        if host:
                            node_details[host] = payload
                current_placement_records: dict[str, dict[str, Any]] = {}
                current_placements: dict[str, dict[str, Any]] = {}
                if placement_prefix:
                    current_placement_records = etcd.get_prefix(placement_prefix)
                    for key, payload in current_placement_records.items():
                        service = key.removeprefix(placement_prefix + "/")
                        if service:
                            current_placements[service] = payload
                request_records: dict[str, dict[str, Any]] = {}
                move_requests: dict[str, dict[str, Any]] = {}
                if request_prefix:
                    request_records = etcd.get_prefix(request_prefix)
                    for key, payload in request_records.items():
                        service = key.removeprefix(request_prefix + "/")
                        if service and isinstance(payload, dict):
                            move_requests[service] = payload
                scheduling_resources = {host: dict(payload) for host, payload in resource_records.items()}
                for placed_unit, placement in current_placements.items():
                    owner = str(placement.get("target_owner") or placement.get("desired_owner") or placement.get("active_owner") or "")
                    policy = getattr(self.config.ha.scheduler, "unit_policies", {}).get(placed_unit)
                    resource = scheduling_resources.get(owner)
                    if not owner or not policy or resource is None:
                        continue
                    resource["memory_available_bytes"] = max(0, _safe_int(resource.get("memory_available_bytes")) - policy.estimated_memory_bytes)
                    cpu_count = max(1, _safe_int(resource.get("cpu_count"), 1))
                    resource["load_1_per_cpu"] = _safe_float(resource.get("load_1_per_cpu")) + (policy.estimated_cpu / cpu_count)
                ownership_records: dict[str, dict[str, Any]] = {}
                ownership_entries: dict[str, dict[str, Any]] = {}
                if ownership_prefix:
                    ownership_entries = etcd.get_prefix_entries(ownership_prefix)
                    for key, entry in ownership_entries.items():
                        service = key.removeprefix(ownership_prefix + "/")
                        if service:
                            ownership_records[service] = dict(entry.get("value", {}))
                stale_runtime_keys = self.stale_runtime_keys(
                    managed_units,
                    placement_prefix,
                    current_placement_records,
                    request_prefix,
                    request_records,
                    ownership_prefix,
                    ownership_entries,
                )
                route_units = {
                    route.unit
                    for route in self.config.ingress_router.routes.values()
                    if route.enable and route.unit
                }
                services: dict[str, dict[str, Any]] = {}
                placement_updates: dict[str, dict[str, Any]] = {}
                for key, payload in records.items():
                    host, service = self.service_and_host_from_key(prefix, key)
                    if not host or not service:
                        continue
                    service_entry = services.setdefault(service, {
                        "candidate_nodes": [], "healthy_nodes": [], "unhealthy_nodes": [], "stale_nodes": [], "recommended_target": None, "reports": {},
                    })
                    service_entry["reports"][host] = payload
                    age = now - int(payload.get("observed_at", 0))
                    if age > stale_after:
                        service_entry["stale_nodes"].append(host)
                    else:
                        if payload.get("load_state") == "loaded":
                            service_entry["candidate_nodes"].append(host)
                        if payload.get("healthy"):
                            service_entry["healthy_nodes"].append(host)
                        else:
                            service_entry["unhealthy_nodes"].append(host)

                for service in managed_units:
                    services.setdefault(service, {
                        "candidate_nodes": [],
                        "healthy_nodes": [],
                        "unhealthy_nodes": [],
                        "stale_nodes": [],
                        "recommended_target": None,
                        "reports": {},
                    })

                for service, payload in services.items():
                    payload["candidate_nodes"].sort()
                    payload["healthy_nodes"].sort()
                    payload["unhealthy_nodes"].sort()
                    payload["stale_nodes"].sort()
                    payload["scheduler_managed"] = service in managed_units
                    if service not in managed_units:
                        payload["recommended_target"] = None
                        payload["resource_ranked_nodes"] = []
                        payload["placement_strategy"] = self.config.ha.scheduler.default_strategy
                        payload["placement_key"] = f"{placement_prefix}/{service}"
                        payload["current_owner"] = None
                        payload["desired_owner"] = None
                        payload["usable"] = False
                        payload["usable_reason"] = "not scheduler workload"
                        payload["routable"] = False
                        payload["route_reason"] = "not scheduler workload"
                        payload["placement_published_at"] = None
                        continue
                    candidate_nodes = payload["candidate_nodes"]
                    healthy_nodes = payload["healthy_nodes"]
                    ranked_nodes = self.rank_nodes_by_resources(
                        candidate_nodes,
                        scheduling_resources,
                        service=service,
                        reports=payload["reports"],
                        now=now,
                        stale_after=resource_stale_after,
                    )
                    current_placement = current_placements.get(service, {})
                    current_owner = str(current_placement.get("desired_owner") or "") or None
                    requested_target, request_update = self.move_request_target(
                        service,
                        move_requests.get(service),
                        candidate_nodes,
                        now,
                    )
                    state = self.advance_placement(
                        service,
                        current_placement,
                        candidate_nodes,
                        healthy_nodes,
                        ranked_nodes,
                        payload["reports"],
                        ownership_records.get(service),
                        now,
                        stale_after,
                        scheduling_resources,
                        requested_target=requested_target,
                    )
                    if request_update is None:
                        request_update = self.update_move_request(move_requests.get(service), state, now)
                    target = state["desired_owner"]
                    prior = current_owner or self.previous_targets.get(service)
                    if prior != target and (prior is not None or target is not None):
                        self.logger.info(
                            "service_target_change service=%s previous=%s current=%s candidate_nodes=%s healthy_nodes=%s",
                            service, prior or "", target or "", ",".join(candidate_nodes), ",".join(healthy_nodes),
                        )
                    payload["recommended_target"] = target
                    payload["resource_ranked_nodes"] = ranked_nodes
                    payload["placement_strategy"] = self.config.ha.scheduler.default_strategy
                    payload["placement_key"] = f"{placement_prefix}/{service}"
                    payload["current_owner"] = current_owner
                    payload["desired_owner"] = target if (is_leader and service in managed_units) else None
                    payload.update({key: value for key, value in state.items() if key != "desired_owner"})
                    route_status = route_status_for_unit(
                        service,
                        {service: {"updated_at": now, **state}},
                        {"observed_at": now, "services": services},
                        self.config.ingress_router.node_addresses,
                        now,
                        stale_after,
                        ownership_records,
                        has_route=service in route_units,
                    )
                    payload.update(route_status)
                    payload["placement_published_at"] = now if (is_leader and service in managed_units) else None
                    self.previous_targets[service] = target
                    if is_leader and service in managed_units:
                        if state["phase"] != "stable":
                            transition_reason = f"handoff_{state['phase']}"
                        elif not candidate_nodes:
                            transition_reason = "no_candidate_nodes"
                        elif requested_target:
                            transition_reason = "operator_requested_move"
                        elif current_owner and current_owner != target:
                            transition_reason = "current_owner_unhealthy_or_less_available"
                        elif current_owner == target:
                            transition_reason = "current_owner_retained"
                        else:
                            transition_reason = "best_available_candidate"
                        placement_updates[payload["placement_key"]] = {
                            "service": service,
                            "current_owner": current_owner,
                            "desired_owner": target,
                            "controller": self.controller,
                            "leader": leader_payload.get("hostname", self.controller),
                            "leader_mode": self.config.ha.scheduler.controller_mode,
                            "placement_strategy": self.config.ha.scheduler.default_strategy,
                            "candidate_nodes": payload["candidate_nodes"],
                            "healthy_nodes": payload["healthy_nodes"],
                            "unhealthy_nodes": payload["unhealthy_nodes"],
                            "stale_nodes": payload["stale_nodes"],
                            "resource_ranked_nodes": ranked_nodes,
                            "transition_reason": transition_reason,
                            "updated_at": now,
                            **state,
                        }
                        if request_update and request_prefix:
                            placement_updates[f"{request_prefix}/{service}"] = request_update
                    if not healthy_nodes:
                        if self.should_log_service_unavailable(service, payload["unhealthy_nodes"], payload["stale_nodes"]):
                            self.logger.warning(
                                "service_unavailable service=%s unhealthy_nodes=%s stale_nodes=%s",
                                service, ",".join(payload["unhealthy_nodes"]), ",".join(payload["stale_nodes"]),
                            )

                managed_registry = {
                    "observed_at": now,
                    "controller": self.controller,
                    "leader": leader_payload.get("hostname", self.controller),
                    "placement_prefix": placement_prefix,
                    "units": sorted(managed_units),
                    "rejected_units": sorted(self.config.ha.scheduler.rejected_managed_units),
                    "workloads": self.config.ha.scheduler.workloads,
                }
                cluster_state = {
                    "controller": self.controller,
                    "observed_at": now,
                    "runtime_store": endpoint,
                    "scheduler": {
                        "controller_mode": self.config.ha.scheduler.controller_mode,
                        "is_leader": is_leader,
                        "leader": leader_payload,
                        "leader_key": self.config.ha.scheduler.leader_key,
                        "placement_prefix": placement_prefix,
                        "resource_prefix": resource_prefix,
                        "default_strategy": self.config.ha.scheduler.default_strategy,
                        "managed_units": sorted(managed_units),
                        "resource_stale_after_seconds": resource_stale_after,
                    },
                    "resources": resource_records,
                    "node_details": node_details,
                    "managed_units": managed_registry,
                    "services": services,
                }
                etcd_updates = {
                    CLUSTER_STATE_KEY: cluster_state,
                    MANAGED_UNITS_KEY: managed_registry,
                }
                if is_leader and placement_updates:
                    etcd_updates.update(placement_updates)
                atomic_write_json(cluster_state_path, cluster_state)
                atomic_write_text(metrics_path, self.build_cluster_metrics(cluster_state))
                if time.monotonic() >= write_backoff_until:
                    try:
                        if is_leader and stale_runtime_keys:
                            etcd.delete_keys(sorted(set(stale_runtime_keys)))
                        etcd.put_json_many(etcd_updates)
                    except RuntimeStoreRateLimited as error:
                        event, retry_after = _runtime_store_warning_details(error, max(5.0, float(interval)))
                        write_backoff_until = time.monotonic() + retry_after
                        self.log_runtime_store_warning(
                            endpoint,
                            "%s endpoint=%s retry_after=%.1fs",
                            event,
                            endpoint,
                            retry_after,
                        )
            except RuntimeStoreRateLimited as error:
                event, retry_after = _runtime_store_warning_details(error, max(5.0, float(interval)))
                write_backoff_until = time.monotonic() + retry_after
                self.log_runtime_store_warning(
                    endpoint,
                    "%s endpoint=%s retry_after=%.1fs",
                    event,
                    endpoint,
                    retry_after,
                )
            except urllib.error.URLError as error:
                self.log_runtime_store_warning(
                    endpoint,
                    "runtime_store_unreachable endpoint=%s error=%s",
                    endpoint,
                    error,
                )
            except Exception as error:
                self.logger.exception("monitor_loop_failed: %s", error)
            time.sleep(interval)


# CLI entry point for `python -m nix_cluster.ha reporter`.
def reporter_main() -> None:
    ServiceReporter().run()


# CLI entry point for `python -m nix_cluster.ha monitor`.
def monitor_main() -> None:
    ClusterMonitor().run()


# CLI entry point for `python -m nix_cluster.ha reconciler`.
def reconciler_main() -> None:
    WorkerReconciler().run()


# CLI entry point for `python -m nix_cluster.ha recovery`.
def recovery_main() -> None:
    LocalRecoveryMonitor().run()


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "reporter"
    if mode == "reporter":
        reporter_main()
    elif mode == "monitor":
        monitor_main()
    elif mode == "reconciler":
        reconciler_main()
    elif mode == "recovery":
        recovery_main()
    else:
        raise SystemExit(f"unknown mode: {mode}")
