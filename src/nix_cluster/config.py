from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any

DEFAULT_CONFIG_PATH = "/etc/nix-cluster-runtime-config.json"
LEGACY_CONFIG_PATH = "/etc/nops-runtime-config.json"


def _as_list(raw: Any) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, list):
        return [str(item) for item in raw if str(item)]
    text = str(raw)
    return [text] if text else []


def _as_bool(raw: Any, default: bool = False) -> bool:
    if raw is None:
        return default
    return bool(raw)


def _as_int(raw: Any, default: int) -> int:
    if raw is None:
        return default
    return int(raw)


def _resolve_config_path(path: str | None) -> str:
    candidates = [
        path,
        os.environ.get("NIX_CLUSTER_CONFIG_PATH"),
        os.environ.get("NOPS_CONFIG_PATH"),
        DEFAULT_CONFIG_PATH,
        LEGACY_CONFIG_PATH,
    ]
    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            return candidate
    return path or os.environ.get("NIX_CLUSTER_CONFIG_PATH") or os.environ.get("NOPS_CONFIG_PATH") or DEFAULT_CONFIG_PATH


@dataclass(slots=True)
class DirectorySettings:
    repo: str
    log: str
    state: str
    metrics: str
    heartbeat: str
    runtime_config: str
    controller_script_dir: str


@dataclass(slots=True)
class UpdateSettings:
    commands: list[str]
    remote_name: str
    branch_ref: str
    relevant_paths: list[str]
    worker_wait_seconds: int


@dataclass(slots=True)
class ControllerMonitorSettings:
    enable: bool
    interval_seconds: int
    targets: list[str]


@dataclass(slots=True)
class ControllerSettings:
    reconcile_interval_seconds: int
    monitor: ControllerMonitorSettings


@dataclass(slots=True)
class PrometheusSettings:
    enable: bool
    port: int


@dataclass(slots=True)
class LokiSettings:
    enable: bool
    url: str


@dataclass(slots=True)
class ObservabilitySettings:
    tracked_units: list[str]
    prometheus: PrometheusSettings
    loki: LokiSettings


@dataclass(slots=True)
class ReportingSettings:
    enable: bool
    mode: str
    services: list[str]
    include_tracked_units: bool
    interval_seconds: int


@dataclass(slots=True)
class LocalRuntimeStoreSettings:
    enable: bool
    name: str
    listen_client_urls: list[str]
    advertise_client_urls: list[str]
    listen_peer_urls: list[str]
    initial_advertise_peer_urls: list[str]
    initial_cluster: list[str]
    initial_cluster_state: str


@dataclass(slots=True)
class RuntimeStoreSettings:
    type: str
    endpoint: str
    key_prefix: str
    inventory_prefix: str
    join_prefix: str
    stale_after_seconds: int
    local_server: LocalRuntimeStoreSettings


@dataclass(slots=True)
class SchedulerSettings:
    enable: bool
    interval_seconds: int


@dataclass(slots=True)
class HASettings:
    enable: bool
    reporting: ReportingSettings
    runtime_store: RuntimeStoreSettings
    scheduler: SchedulerSettings


@dataclass(slots=True)
class MatrixSettings:
    enable: bool
    trigger_keywords: list[str]


@dataclass(slots=True)
class WebhookSettings:
    enable: bool
    bind_address: str
    port: int
    ssl_cert: str
    ssl_key: str
    skip_commit_marker: str


@dataclass(slots=True)
class RuntimeConfig:
    path: str
    raw: dict[str, Any]
    is_controller: bool
    controller_script: str
    hostname: str
    directories: DirectorySettings
    update: UpdateSettings
    controller: ControllerSettings
    observability: ObservabilitySettings
    ha: HASettings
    matrix: MatrixSettings
    webhook: WebhookSettings

    @classmethod
    def from_path(cls, path: str | None = None) -> "RuntimeConfig":
        resolved = _resolve_config_path(path)
        with open(resolved, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
        return cls.from_raw(resolved, raw)

    @classmethod
    def from_raw(cls, path: str, raw: dict[str, Any]) -> "RuntimeConfig":
        directories_raw = raw.get("directories", {})
        update_raw = raw.get("update", raw.get("commands", {}))
        controller_raw = raw.get("controller", {})
        monitor_raw = controller_raw.get("monitor", {})
        observability_raw = raw.get("observability", {})
        prometheus_raw = observability_raw.get("prometheus", {})
        loki_raw = observability_raw.get("loki", {})
        ha_raw = raw.get("ha", {})
        reporting_raw = ha_raw.get("reporting", {})
        runtime_store_raw = ha_raw.get("runtime_store", {})
        local_server_raw = runtime_store_raw.get("local_server", {})
        scheduler_raw = ha_raw.get("scheduler", {})
        matrix_raw = raw.get("matrix", {})
        webhook_raw = raw.get("webhook", {})

        directories = DirectorySettings(
            repo=str(directories_raw.get("repo", "")),
            log=str(directories_raw.get("log", "/home/nix-cluster/log")),
            state=str(directories_raw.get("state", "/var/lib/nix-cluster")),
            metrics=str(directories_raw.get("metrics", "/var/lib/nix-cluster/metrics")),
            heartbeat=str(directories_raw.get("heartbeat", "/var/lib/nix-cluster-heartbeat")),
            runtime_config=str(directories_raw.get("runtime_config", path)),
            controller_script_dir=str(directories_raw.get("controller_script_dir", "/var/lib/nix-cluster")),
        )

        update = UpdateSettings(
            commands=_as_list(update_raw.get("update", [])),
            remote_name=str(update_raw.get("remote_name", "origin")),
            branch_ref=str(update_raw.get("branch_ref", "origin/main")),
            relevant_paths=_as_list(update_raw.get("relevant_paths", [])),
            worker_wait_seconds=_as_int(update_raw.get("worker_wait_seconds"), 30),
        )

        controller = ControllerSettings(
            reconcile_interval_seconds=_as_int(controller_raw.get("reconcile_interval_seconds"), 0),
            monitor=ControllerMonitorSettings(
                enable=_as_bool(monitor_raw.get("enable"), True),
                interval_seconds=_as_int(monitor_raw.get("interval_seconds"), 15),
                targets=_as_list(monitor_raw.get("targets", [])),
            ),
        )

        observability = ObservabilitySettings(
            tracked_units=_as_list(observability_raw.get("tracked_units", [])),
            prometheus=PrometheusSettings(
                enable=_as_bool(prometheus_raw.get("enable"), False),
                port=_as_int(prometheus_raw.get("port"), 9100),
            ),
            loki=LokiSettings(
                enable=_as_bool(loki_raw.get("enable"), False),
                url=str(loki_raw.get("url", "")),
            ),
        )

        ha = HASettings(
            enable=_as_bool(ha_raw.get("enable"), False),
            reporting=ReportingSettings(
                enable=_as_bool(reporting_raw.get("enable"), False),
                mode=str(reporting_raw.get("mode", "only")),
                services=_as_list(reporting_raw.get("services", [])),
                include_tracked_units=_as_bool(reporting_raw.get("include_tracked_units"), True),
                interval_seconds=_as_int(reporting_raw.get("interval_seconds"), 5),
            ),
            runtime_store=RuntimeStoreSettings(
                type=str(runtime_store_raw.get("type", "none")),
                endpoint=str(runtime_store_raw.get("endpoint", "")),
                key_prefix=str(runtime_store_raw.get("key_prefix", "/nix-cluster/health")),
                inventory_prefix=str(runtime_store_raw.get("inventory_prefix", "/nix-cluster/inventory")),
                join_prefix=str(runtime_store_raw.get("join_prefix", "/nix-cluster/join")),
                stale_after_seconds=_as_int(runtime_store_raw.get("stale_after_seconds"), 15),
                local_server=LocalRuntimeStoreSettings(
                    enable=_as_bool(local_server_raw.get("enable"), False),
                    name=str(local_server_raw.get("name", "")),
                    listen_client_urls=_as_list(local_server_raw.get("listen_client_urls", [])),
                    advertise_client_urls=_as_list(local_server_raw.get("advertise_client_urls", [])),
                    listen_peer_urls=_as_list(local_server_raw.get("listen_peer_urls", [])),
                    initial_advertise_peer_urls=_as_list(local_server_raw.get("initial_advertise_peer_urls", [])),
                    initial_cluster=_as_list(local_server_raw.get("initial_cluster", [])),
                    initial_cluster_state=str(local_server_raw.get("initial_cluster_state", "new")),
                ),
            ),
            scheduler=SchedulerSettings(
                enable=_as_bool(scheduler_raw.get("enable"), False),
                interval_seconds=_as_int(scheduler_raw.get("interval_seconds"), 5),
            ),
        )

        matrix = MatrixSettings(
            enable=_as_bool(matrix_raw.get("enable"), True),
            trigger_keywords=[keyword.lower() for keyword in _as_list(matrix_raw.get("trigger_keywords", ["push", "commit", "update"]))],
        )

        webhook = WebhookSettings(
            enable=_as_bool(webhook_raw.get("enable"), False),
            bind_address=str(webhook_raw.get("bind_address", "0.0.0.0")),
            port=_as_int(webhook_raw.get("port"), 8080),
            ssl_cert=str(webhook_raw.get("ssl_cert", "")),
            ssl_key=str(webhook_raw.get("ssl_key", "")),
            skip_commit_marker=str(webhook_raw.get("skip_commit_marker", "[skip nix-cluster]")),
        )

        return cls(
            path=path,
            raw=raw,
            is_controller=_as_bool(raw.get("is_controller"), False),
            controller_script=str(raw.get("controller_script", "")),
            hostname=str(raw.get("hostname", "")),
            directories=directories,
            update=update,
            controller=controller,
            observability=observability,
            ha=ha,
            matrix=matrix,
            webhook=webhook,
        )

    @property
    def repo_dir(self) -> str:
        return self.directories.repo

    @property
    def update_commands(self) -> list[str]:
        return self.update.commands
