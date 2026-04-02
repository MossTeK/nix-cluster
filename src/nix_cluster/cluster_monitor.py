from __future__ import annotations

import socket
import time
import urllib.error
from pathlib import Path
from typing import Any

from .etcd_client import EtcdClient
from .file_utils import atomic_write_json, atomic_write_text
from .logging_utils import configure_logging
from .runtime_config import RuntimeConfig


class ClusterMonitor:
    def __init__(self, config_path: str | None = None):
        self.config = RuntimeConfig.from_path(config_path)
        self.logger = configure_logging("nix-cluster-monitor")
        self.controller = socket.gethostname()
        self.previous_targets: dict[str, str] = {}

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
        services = cluster_state.get("services", {})
        for service, payload in sorted(services.items()):
            lines.append(
                f'nix_cluster_service_instances{{service="{service}",state="healthy"}} {len(payload.get("healthy_nodes", []))}'
            )
            lines.append(
                f'nix_cluster_service_instances{{service="{service}",state="unhealthy"}} {len(payload.get("unhealthy_nodes", []))}'
            )
            lines.append(
                f'nix_cluster_service_instances{{service="{service}",state="stale"}} {len(payload.get("stale_nodes", []))}'
            )

        lines.extend(
            [
                "# HELP nix_cluster_monitor_timestamp_seconds Unix timestamp of the most recent controller aggregation pass.",
                "# TYPE nix_cluster_monitor_timestamp_seconds gauge",
                f'nix_cluster_monitor_timestamp_seconds{{host="{self.controller}"}} {int(time.time())}',
            ]
        )
        return "\n".join(lines) + "\n"

    def run(self) -> None:
        ha_cfg = self.config.ha
        runtime_store = ha_cfg.get("runtime_store", {})
        scheduler_cfg = ha_cfg.get("scheduler", {})
        if not self.config.is_controller:
            self.logger.info("monitor disabled on non-controller node")
            return
        if not (ha_cfg.get("enable") and scheduler_cfg.get("enable")):
            self.logger.info("controller scheduler disabled")
            return
        if runtime_store.get("type") != "etcd" or not runtime_store.get("endpoint"):
            self.logger.info("controller scheduler requires an etcd runtime store endpoint")
            return

        endpoint = runtime_store["endpoint"]
        prefix = runtime_store.get("key_prefix", "/nix-cluster/health")
        stale_after = max(1, int(runtime_store.get("stale_after_seconds", 15)))
        interval = max(1, int(scheduler_cfg.get("interval_seconds", 5)))
        state_root = Path(self.config.directories.get("state", "/var/lib/nops"))
        metrics_root = Path(self.config.directories.get("metrics", "/var/lib/nops/metrics"))
        cluster_state_path = state_root / "ha" / "cluster-state.json"
        metrics_path = metrics_root / "cluster-state.prom"
        etcd = EtcdClient(endpoint)

        self.logger.info("starting controller monitor on %s", self.controller)
        while True:
            try:
                now = int(time.time())
                records = etcd.get_prefix(prefix)
                services: dict[str, dict[str, Any]] = {}

                for key, payload in records.items():
                    host, service = self.service_and_host_from_key(prefix, key)
                    if not host or not service:
                        continue

                    service_entry = services.setdefault(
                        service,
                        {
                            "healthy_nodes": [],
                            "unhealthy_nodes": [],
                            "stale_nodes": [],
                            "recommended_target": None,
                            "reports": {},
                        },
                    )
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
                    prior = self.previous_targets.get(service)
                    healthy_nodes = payload["healthy_nodes"]
                    target = prior if prior in healthy_nodes else (healthy_nodes[0] if healthy_nodes else None)
                    if prior != target:
                        self.logger.info(
                            "service_target_change service=%s previous=%s current=%s healthy_nodes=%s",
                            service,
                            prior or "",
                            target or "",
                            ",".join(healthy_nodes),
                        )
                    payload["recommended_target"] = target
                    self.previous_targets[service] = target or ""

                    if not healthy_nodes:
                        self.logger.warning(
                            "service_unavailable service=%s unhealthy_nodes=%s stale_nodes=%s",
                            service,
                            ",".join(payload["unhealthy_nodes"]),
                            ",".join(payload["stale_nodes"]),
                        )

                cluster_state = {
                    "controller": self.controller,
                    "observed_at": now,
                    "runtime_store": endpoint,
                    "services": services,
                }
                atomic_write_json(cluster_state_path, cluster_state)
                atomic_write_text(metrics_path, self.build_cluster_metrics(cluster_state))
            except urllib.error.URLError as error:
                self.logger.warning("runtime_store_unreachable endpoint=%s error=%s", endpoint, error)
            except Exception as error:
                self.logger.exception("monitor_loop_failed: %s", error)

            time.sleep(interval)


def main() -> None:
    ClusterMonitor().run()
