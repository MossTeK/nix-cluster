from __future__ import annotations

import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from .config import RuntimeConfig
from .core import atomic_write_json, atomic_write_text, configure_logging
from .runtime import EtcdClient, RuntimeStoreRateLimited, RuntimeStoreWriteBlocked

ACTIVE_STATES = {"active", "activating", "reloading"}
HEALTHY_ACTIVE_STATES = {"active", "reloading"}
REPEATED_WARNING_INTERVAL_SECONDS = 60.0
MIN_AVAILABLE_MEMORY_BYTES = 512 * 1024 * 1024
MIN_STATE_FREE_BYTES = 2 * 1024 * 1024 * 1024
CLUSTER_STATE_KEY = "/nix-cluster/cluster-state"
NODE_DETAIL_PREFIX = "/nix-cluster/node-details"
MANAGED_UNITS_KEY = "/nix-cluster/scheduler/managed-units"
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


def _safe_int(raw: Any, default: int = 0) -> int:
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def _safe_float(raw: Any, default: float = 0.0) -> float:
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


def _dedupe_preserve_order(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if not value or value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def _runtime_store_warning_details(error: RuntimeStoreRateLimited, default_retry_after: float) -> tuple[str, float]:
    retry_after = error.retry_after if error.retry_after is not None else default_retry_after
    if isinstance(error, RuntimeStoreWriteBlocked):
        return "runtime_store_write_blocked", retry_after
    return "runtime_store_rate_limited", retry_after


def _payload_digest(payload: dict[str, Any]) -> str:
    stable_payload = dict(payload)
    stable_payload.pop("observed_at", None)
    encoded = json.dumps(stable_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class ServiceReporter:
    def __init__(self, config_path: str | None = None):
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-reporter")
        self.hostname = socket.gethostname()
        self.previous_states: dict[str, bool] = {}
        self.previous_payload_hashes: dict[str, str] = {}
        self.previous_etcd_write_at: dict[str, float] = {}
        self.last_runtime_store_warning: tuple[str, str] | None = None
        self.last_runtime_store_warning_at = 0.0

    def log_runtime_store_warning(self, endpoint: str, message: str, *args: Any) -> None:
        rendered = message % args if args else message
        signature = (endpoint, rendered)
        now = time.monotonic()
        if signature == self.last_runtime_store_warning and (now - self.last_runtime_store_warning_at) < REPEATED_WARNING_INTERVAL_SECONDS:
            return
        self.last_runtime_store_warning = signature
        self.last_runtime_store_warning_at = now
        self.logger.warning(message, *args)

    def run_command(self, command: list[str]) -> str:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"command failed: {' '.join(command)}")
        return result.stdout

    def list_all_service_units(self) -> set[str]:
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

    def build_metric_lines(self, services: dict[str, dict[str, Any]]) -> str:
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
        ])
        return "\n".join(lines) + "\n"

    def selected_units(self, all_units: set[str]) -> list[str]:
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
                units = self.selected_units(self.list_all_service_units())
                services: dict[str, dict[str, Any]] = {}
                etcd_updates: dict[str, dict[str, Any]] = {}
                for unit in units:
                    payload = self.collect_unit_status(unit)
                    services[unit] = payload
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


class WorkerReconciler:
    def __init__(self, config_path: str | None = None):
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-reconciler")
        self.hostname = socket.gethostname()
        self.previous_assignments: dict[str, str | None] = {}
        self.last_runtime_store_warning: tuple[str, str] | None = None
        self.last_runtime_store_warning_at = 0.0

    def log_runtime_store_warning(self, endpoint: str, message: str, *args: Any) -> None:
        rendered = message % args if args else message
        signature = (endpoint, rendered)
        now = time.monotonic()
        if signature == self.last_runtime_store_warning and (now - self.last_runtime_store_warning_at) < REPEATED_WARNING_INTERVAL_SECONDS:
            return
        self.last_runtime_store_warning = signature
        self.last_runtime_store_warning_at = now
        self.logger.warning(message, *args)

    def run_command(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(command, capture_output=True, text=True, check=False)

    def collect_unit_status(self, unit: str, now: int) -> dict[str, Any]:
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
        try:
            with open("/proc/uptime", "r", encoding="utf-8") as handle:
                return _safe_float(handle.read().split()[0])
        except (OSError, IndexError):
            return 0.0

    def collect_disk_snapshots(self) -> list[dict[str, Any]]:
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
        schedulable = memory_available_bytes >= MIN_AVAILABLE_MEMORY_BYTES and state_dir_free_bytes >= MIN_STATE_FREE_BYTES

        return {
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
        }

    def build_node_detail(
        self,
        resource_snapshot: dict[str, Any],
        units: dict[str, dict[str, Any]],
        now: int,
    ) -> dict[str, Any]:
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

        result = self.run_command(["sudo", "systemctl", verb, unit])
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
        resource_prefix = self.config.ha.scheduler.resource_prefix.rstrip("/")
        node_detail_prefix = NODE_DETAIL_PREFIX.rstrip("/")
        reconcile_state_path = Path(self.config.directories.state) / "ha" / "scheduler-reconciler.json"
        resource_state_path = Path(self.config.directories.state) / "ha" / "scheduler-resources.json"
        metrics_path = Path(self.config.directories.metrics) / "scheduler-reconciler.prom"
        write_backoff_until = 0.0
        next_resource_publish_at = 0.0
        last_resource_snapshot: dict[str, Any] | None = None

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
                    action = self.reconcile_unit(
                        unit,
                        has_placement=has_placement,
                        desired_owner=desired_owner or None,
                        status_before=status_before,
                    )
                    status_after = self.collect_unit_status(unit, now)
                    active_local = status_after.get("load_state") == "loaded" and status_after.get("active_state") in ACTIVE_STATES
                    units[unit] = {
                        "desired_owner": desired_owner or None,
                        "desired_local": bool(action.get("desired_local")),
                        "active_local": active_local,
                        "has_placement": has_placement,
                        "placement_key": placement_key,
                        "placement_updated_at": _safe_int(placement_payload.get("updated_at")) if placement_payload else 0,
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
                self.logger.exception("reconciler_loop_failed: %s", error)
            time.sleep(interval)


class ClusterMonitor:
    def __init__(self, config_path: str | None = None):
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
        rendered = message % args if args else message
        signature = (endpoint, rendered)
        now = time.monotonic()
        if signature == self.last_runtime_store_warning and (now - self.last_runtime_store_warning_at) < REPEATED_WARNING_INTERVAL_SECONDS:
            return
        self.last_runtime_store_warning = signature
        self.last_runtime_store_warning_at = now
        self.logger.warning(message, *args)

    def should_log_service_unavailable(self, service: str, unhealthy_nodes: list[str], stale_nodes: list[str]) -> bool:
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
        trimmed = key.removeprefix(prefix.rstrip("/") + "/")
        host, _, unit = trimmed.partition("/")
        return host, unit

    @staticmethod
    def host_from_resource_key(prefix: str, key: str) -> str:
        return key.removeprefix(prefix.rstrip("/") + "/")

    def build_leader_payload(self, now: int, lease_id: int = 0) -> dict[str, Any]:
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
        fixed_host = self.config.ha.scheduler.fixed_controller_host.strip()
        if fixed_host:
            return fixed_host
        return self.controller

    def note_leadership_state(self, is_leader: bool, leader_payload: dict[str, Any]) -> None:
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
        if not payload:
            return False
        return (now - _safe_int(payload.get("observed_at"))) <= stale_after

    def resource_record_is_schedulable(self, payload: dict[str, Any] | None, now: int, stale_after: int) -> bool:
        if not self.resource_record_is_fresh(payload, now, stale_after):
            return False
        return bool(payload.get("schedulable", True))

    def rank_nodes_by_resources(
        self,
        candidate_nodes: list[str],
        resource_records: dict[str, dict[str, Any]],
        *,
        reports: dict[str, dict[str, Any]] | None = None,
        now: int,
        stale_after: int,
    ) -> list[str]:
        def resource_sort_key(host: str) -> tuple[int, int, int, int, int, float, str]:
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
                return (service_state_rank, 1, 1, 0, 0, 9999.0, host)
            return (
                service_state_rank,
                0 if bool(payload.get("schedulable", True)) else 1,
                0 if bool(payload.get("controller_reachable", True)) else 1,
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
        if not candidate_nodes:
            return None
        strategy = self.config.ha.scheduler.default_strategy
        prior = current_owner or self.previous_targets.get(service)
        ranked_nodes = self.rank_nodes_by_resources(candidate_nodes, resource_records, reports=reports, now=now, stale_after=stale_after)
        schedulable_nodes = [
            host for host in ranked_nodes
            if self.resource_record_is_schedulable(resource_records.get(host), now, stale_after)
        ]

        if strategy == "prefer-current-healthy" and prior in healthy_nodes:
            if not schedulable_nodes or self.resource_record_is_schedulable(resource_records.get(prior), now, stale_after):
                return prior

        if schedulable_nodes:
            if prior and prior not in healthy_nodes:
                next_nodes = [host for host in schedulable_nodes if host != prior]
                if next_nodes:
                    return next_nodes[0]
            return schedulable_nodes[0]
        if prior and prior not in healthy_nodes:
            next_nodes = [host for host in ranked_nodes if host != prior]
            if next_nodes:
                return next_nodes[0]
        return ranked_nodes[0]

    def build_cluster_metrics(self, cluster_state: dict[str, Any]) -> str:
        lines = [
            "# HELP nix_cluster_service_instances Number of nodes currently reporting a service by health state.",
            "# TYPE nix_cluster_service_instances gauge",
        ]
        for service, payload in sorted(cluster_state.get("services", {}).items()):
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="candidate"}} {len(payload.get("candidate_nodes", []))}')
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="healthy"}} {len(payload.get("healthy_nodes", []))}')
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="unhealthy"}} {len(payload.get("unhealthy_nodes", []))}')
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="stale"}} {len(payload.get("stale_nodes", []))}')
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
        for service, payload in sorted(cluster_state.get("services", {}).items()):
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
        node_detail_prefix = NODE_DETAIL_PREFIX.rstrip("/")
        write_backoff_until = 0.0

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
                current_placements: dict[str, dict[str, Any]] = {}
                if placement_prefix:
                    for key, payload in etcd.get_prefix(placement_prefix).items():
                        service = key.removeprefix(placement_prefix + "/")
                        if service:
                            current_placements[service] = payload
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
                    candidate_nodes = payload["candidate_nodes"]
                    healthy_nodes = payload["healthy_nodes"]
                    ranked_nodes = self.rank_nodes_by_resources(
                        candidate_nodes,
                        resource_records,
                        reports=payload["reports"],
                        now=now,
                        stale_after=resource_stale_after,
                    )
                    current_placement = current_placements.get(service, {})
                    current_owner = str(current_placement.get("desired_owner") or "") or None
                    target = self.choose_desired_owner(
                        service,
                        candidate_nodes,
                        healthy_nodes,
                        resource_records,
                        reports=payload["reports"],
                        current_owner=current_owner,
                        now=now,
                        stale_after=resource_stale_after,
                    )
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
                    payload["scheduler_managed"] = service in managed_units
                    payload["current_owner"] = current_owner
                    payload["desired_owner"] = target if (is_leader and service in managed_units) else None
                    payload["placement_published_at"] = now if (is_leader and service in managed_units) else None
                    self.previous_targets[service] = target
                    if is_leader and service in managed_units:
                        if not candidate_nodes:
                            transition_reason = "no_candidate_nodes"
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
                        }
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


def reporter_main() -> None:
    ServiceReporter().run()


def monitor_main() -> None:
    ClusterMonitor().run()


def reconciler_main() -> None:
    WorkerReconciler().run()


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "reporter"
    if mode == "reporter":
        reporter_main()
    elif mode == "monitor":
        monitor_main()
    elif mode == "reconciler":
        reconciler_main()
    else:
        raise SystemExit(f"unknown mode: {mode}")
