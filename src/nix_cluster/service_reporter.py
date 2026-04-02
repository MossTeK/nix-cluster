from __future__ import annotations

import socket
import subprocess
import time
import urllib.error
from pathlib import Path
from typing import Any

from .etcd_client import EtcdClient
from .file_utils import atomic_write_json, atomic_write_text
from .logging_utils import configure_logging
from .runtime_config import RuntimeConfig

ACTIVE_STATES = {"active", "activating", "reloading"}


class ServiceReporter:
    def __init__(self, config_path: str | None = None):
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-reporter")
        self.hostname = socket.gethostname()
        self.previous_states: dict[str, bool] = {}

    def run_command(self, command: list[str]) -> str:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"command failed: {' '.join(command)}")
        return result.stdout

    def list_all_service_units(self) -> set[str]:
        output = self.run_command(
            [
                "systemctl",
                "list-unit-files",
                "--type=service",
                "--plain",
                "--no-legend",
                "--no-pager",
            ]
        )
        units: set[str] = set()
        for line in output.splitlines():
            parts = line.split()
            if parts and parts[0].endswith(".service"):
                units.add(parts[0])
        return units

    def collect_unit_status(self, unit: str) -> dict[str, Any]:
        output = self.run_command(
            [
                "systemctl",
                "show",
                unit,
                "--property=Id",
                "--property=LoadState",
                "--property=ActiveState",
                "--property=SubState",
                "--property=UnitFileState",
                "--property=Result",
                "--property=ExecMainPID",
                "--property=ExecMainStatus",
                "--property=ActiveEnterTimestamp",
            ]
        )
        values: dict[str, str] = {}
        for line in output.splitlines():
            if "=" not in line:
                continue
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

        lines.extend(
            [
                "# HELP nix_cluster_report_timestamp_seconds Unix timestamp of the most recent reporter pass.",
                "# TYPE nix_cluster_report_timestamp_seconds gauge",
                f'nix_cluster_report_timestamp_seconds{{host="{self.hostname}"}} {int(time.time())}',
            ]
        )
        return "\n".join(lines) + "\n"

    def selected_units(self, all_units: set[str]) -> list[str]:
        ha_cfg = self.config.ha
        reporting_cfg = ha_cfg.get("reporting", {})
        tracked_units = set(self.config.observability.get("tracked_units", []))
        configured_units = set(reporting_cfg.get("services", []))
        include_tracked = reporting_cfg.get("include_tracked_units", True)
        mode = reporting_cfg.get("mode", "only")

        if mode in {"only", "none_except"}:
            units = set(configured_units)
            if include_tracked:
                units |= tracked_units
            return sorted(unit for unit in units if unit)

        units = set(all_units)
        if include_tracked:
            units |= tracked_units
        units -= configured_units
        return sorted(unit for unit in units if unit)

    def run(self) -> None:
        ha_cfg = self.config.ha
        reporting_cfg = ha_cfg.get("reporting", {})
        if not (ha_cfg.get("enable") and reporting_cfg.get("enable")):
            self.logger.info("service reporting disabled")
            return

        state_root = Path(self.config.directories.get("state", "/var/lib/nops"))
        metrics_root = Path(self.config.directories.get("metrics", "/var/lib/nops/metrics"))
        snapshot_path = state_root / "ha" / "service-health.json"
        metrics_path = metrics_root / "service-health.prom"
        runtime_store = ha_cfg.get("runtime_store", {})
        runtime_enabled = runtime_store.get("type") == "etcd" and runtime_store.get("endpoint")
        etcd = EtcdClient(runtime_store["endpoint"]) if runtime_enabled else None
        key_prefix = runtime_store.get("key_prefix", "/nix-cluster/health").rstrip("/")
        interval = max(1, int(reporting_cfg.get("interval_seconds", 5)))

        self.logger.info("starting service reporter on %s", self.hostname)
        while True:
            try:
                units = self.selected_units(self.list_all_service_units())
                services: dict[str, dict[str, Any]] = {}
                for unit in units:
                    payload = self.collect_unit_status(unit)
                    services[unit] = payload

                    prior = self.previous_states.get(unit)
                    current = bool(payload["healthy"])
                    if prior is None or prior != current:
                        self.logger.info(
                            "service_state_change host=%s unit=%s healthy=%s active_state=%s sub_state=%s",
                            self.hostname,
                            unit,
                            str(current).lower(),
                            payload["active_state"],
                            payload["sub_state"],
                        )
                    self.previous_states[unit] = current

                    if etcd:
                        etcd.put_json(f"{key_prefix}/{self.hostname}/{unit}", payload)

                snapshot = {"host": self.hostname, "observed_at": int(time.time()), "services": services}
                atomic_write_json(snapshot_path, snapshot)
                atomic_write_text(metrics_path, self.build_metric_lines(services))
            except urllib.error.URLError as error:
                self.logger.warning(
                    "runtime_store_unreachable endpoint=%s error=%s",
                    runtime_store.get("endpoint", ""),
                    error,
                )
            except Exception as error:
                self.logger.exception("reporter_loop_failed: %s", error)

            time.sleep(interval)


def main() -> None:
    ServiceReporter().run()
