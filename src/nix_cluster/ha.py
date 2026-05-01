from __future__ import annotations

import socket
import subprocess
import sys
import time
import urllib.error
from pathlib import Path
from typing import Any

from .config import RuntimeConfig
from .core import atomic_write_json, atomic_write_text, configure_logging
from .runtime import EtcdClient, RuntimeStoreRateLimited

ACTIVE_STATES = {"active", "activating", "reloading"}
REPEATED_WARNING_INTERVAL_SECONDS = 60.0


class ServiceReporter:
    def __init__(self, config_path: str | None = None):
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-reporter")
        self.hostname = socket.gethostname()
        self.previous_states: dict[str, bool] = {}
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
            "healthy": active_state in ACTIVE_STATES and values.get("LoadState", "") == "loaded",
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
        interval = max(1, self.config.ha.reporting.interval_seconds)
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
                        etcd_updates[f"{key_prefix}/{self.hostname}/{unit}"] = payload

                atomic_write_json(snapshot_path, {"host": self.hostname, "observed_at": int(time.time()), "services": services})
                atomic_write_text(metrics_path, self.build_metric_lines(services))
                if etcd and time.monotonic() >= backoff_until:
                    etcd.put_json_many(etcd_updates)
            except RuntimeStoreRateLimited as error:
                retry_after = error.retry_after if error.retry_after is not None else max(5.0, float(interval))
                backoff_until = time.monotonic() + retry_after
                self.log_runtime_store_warning(
                    runtime_store.endpoint,
                    "runtime_store_rate_limited endpoint=%s retry_after=%.1fs",
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


class ClusterMonitor:
    def __init__(self, config_path: str | None = None):
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-monitor")
        self.controller = socket.gethostname()
        self.previous_targets: dict[str, str] = {}
        self.previous_unavailable_signatures: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {}
        self.previous_unavailable_logged_at: dict[str, float] = {}
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

    def build_cluster_metrics(self, cluster_state: dict[str, Any]) -> str:
        lines = [
            "# HELP nix_cluster_service_instances Number of nodes currently reporting a service by health state.",
            "# TYPE nix_cluster_service_instances gauge",
        ]
        for service, payload in sorted(cluster_state.get("services", {}).items()):
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="healthy"}} {len(payload.get("healthy_nodes", []))}')
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="unhealthy"}} {len(payload.get("unhealthy_nodes", []))}')
            lines.append(f'nix_cluster_service_instances{{service="{service}",state="stale"}} {len(payload.get("stale_nodes", []))}')
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
        interval = max(1, self.config.ha.scheduler.interval_seconds)
        cluster_state_path = Path(self.config.directories.state) / "ha" / "cluster-state.json"
        metrics_path = Path(self.config.directories.metrics) / "cluster-state.prom"
        etcd = EtcdClient(endpoint)
        backoff_until = 0.0

        self.logger.info("starting controller monitor on %s", self.controller)
        while True:
            try:
                if time.monotonic() < backoff_until:
                    time.sleep(interval)
                    continue
                now = int(time.time())
                records = etcd.get_prefix(prefix)
                services: dict[str, dict[str, Any]] = {}
                for key, payload in records.items():
                    host, service = self.service_and_host_from_key(prefix, key)
                    if not host or not service:
                        continue
                    service_entry = services.setdefault(service, {
                        "healthy_nodes": [], "unhealthy_nodes": [], "stale_nodes": [], "recommended_target": None, "reports": {},
                    })
                    service_entry["reports"][host] = payload
                    age = now - int(payload.get("observed_at", 0))
                    if age > stale_after:
                        service_entry["stale_nodes"].append(host)
                    elif payload.get("healthy"):
                        service_entry["healthy_nodes"].append(host)
                    else:
                        service_entry["unhealthy_nodes"].append(host)

                for service, payload in services.items():
                    payload["healthy_nodes"].sort()
                    payload["unhealthy_nodes"].sort()
                    payload["stale_nodes"].sort()
                    prior = self.previous_targets.get(service) or None
                    healthy_nodes = payload["healthy_nodes"]
                    target = prior if prior in healthy_nodes else (healthy_nodes[0] if healthy_nodes else None)
                    if prior != target:
                        self.logger.info(
                            "service_target_change service=%s previous=%s current=%s healthy_nodes=%s",
                            service, prior or "", target or "", ",".join(healthy_nodes),
                        )
                    payload["recommended_target"] = target
                    self.previous_targets[service] = target or ""
                    if not healthy_nodes:
                        if self.should_log_service_unavailable(service, payload["unhealthy_nodes"], payload["stale_nodes"]):
                            self.logger.warning(
                                "service_unavailable service=%s unhealthy_nodes=%s stale_nodes=%s",
                                service, ",".join(payload["unhealthy_nodes"]), ",".join(payload["stale_nodes"]),
                            )

                cluster_state = {"controller": self.controller, "observed_at": now, "runtime_store": endpoint, "services": services}
                atomic_write_json(cluster_state_path, cluster_state)
                atomic_write_text(metrics_path, self.build_cluster_metrics(cluster_state))
            except RuntimeStoreRateLimited as error:
                retry_after = error.retry_after if error.retry_after is not None else max(5.0, float(interval))
                backoff_until = time.monotonic() + retry_after
                self.log_runtime_store_warning(
                    endpoint,
                    "runtime_store_rate_limited endpoint=%s retry_after=%.1fs",
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


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "reporter"
    if mode == "reporter":
        reporter_main()
    elif mode == "monitor":
        monitor_main()
    else:
        raise SystemExit(f"unknown mode: {mode}")
