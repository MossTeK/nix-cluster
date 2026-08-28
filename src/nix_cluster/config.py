from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any

DEFAULT_CONFIG_PATH = "/etc/nix-cluster-runtime-config.json"
LEGACY_CONFIG_PATH = "/etc/nops-runtime-config.json"


# Normalize loose JSON values into a list of non-empty strings.
def _as_list(raw: Any) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, list):
        return [str(item) for item in raw if str(item)]
    text = str(raw)
    return [text] if text else []


# Read a boolean-ish config value, falling back only when it is missing.
def _as_bool(raw: Any, default: bool = False) -> bool:
    if raw is None:
        return default
    return bool(raw)


# Read an integer config value, with a default for omitted fields.
def _as_int(raw: Any, default: int) -> int:
    if raw is None:
        return default
    return int(raw)


# Find the runtime config path, including old `nops` names for upgrades.
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
# Filesystem paths shared by the Python daemons and helper scripts.
class DirectorySettings:
    repo: str
    log: str
    state: str
    metrics: str
    heartbeat: str
    runtime_config: str
    controller_script_dir: str


@dataclass(slots=True)
# Git remote, branch, rebuild commands, and path filters for update runs.
class UpdateSettings:
    commands: list[str]
    remote_name: str
    branch_ref: str
    relevant_paths: list[str]
    worker_wait_seconds: int


@dataclass(slots=True)
# Worker-side controller reachability checks written by the heartbeat helper.
class ControllerMonitorSettings:
    enable: bool
    interval_seconds: int
    targets: list[str]


@dataclass(slots=True)
# Controller-only timing knobs, currently periodic reconciliation and monitoring.
class ControllerSettings:
    reconcile_interval_seconds: int
    monitor: ControllerMonitorSettings


@dataclass(slots=True)
# Static role labels for this node, used by modules and HA decisions.
class PlacementSettings:
    node_role: str
    ha_role: str
    keepalived_role: str


@dataclass(slots=True)
# Whether node-exporter textfile metrics are expected and where they are exposed.
class PrometheusSettings:
    enable: bool
    port: int


@dataclass(slots=True)
# Optional journal shipping target for Promtail.
class LokiSettings:
    enable: bool
    url: str


@dataclass(slots=True)
# Service units and metrics/logging integrations that runtime tools should watch.
class ObservabilitySettings:
    tracked_units: list[str]
    prometheus: PrometheusSettings
    loki: LokiSettings


@dataclass(slots=True)
# Local critical-unit restart policy, independent of fleet HA placement.
class LocalRecoverySettings:
    enable: bool
    critical_units: list[str]
    interval_seconds: int
    dry_run: bool


@dataclass(slots=True)
# Which systemd units the HA reporter should publish.
class ReportingSettings:
    enable: bool
    mode: str
    services: list[str]
    include_tracked_units: bool
    interval_seconds: int
    collection_deadline_seconds: int


@dataclass(slots=True)
# Settings for the optional local etcd process managed by the NixOS module.
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
# Cross-node runtime-state backend, usually etcd when HA is enabled.
class RuntimeStoreSettings:
    type: str
    endpoint: str
    key_prefix: str
    inventory_prefix: str
    join_prefix: str
    stale_after_seconds: int
    local_server: LocalRuntimeStoreSettings


@dataclass(slots=True)
# How controller nodes choose service owners and how workers apply that choice.
class SchedulerSettings:
    enable: bool
    interval_seconds: int
    controller_mode: str
    fixed_controller_host: str
    leader_key: str
    placement_prefix: str
    request_prefix: str
    lease_ttl_seconds: int
    default_strategy: str
    managed_units: list[str]
    app_groups: dict[str, list[str]]
    reconciler_enable: bool
    reconciler_interval_seconds: int
    reconciler_dry_run: bool
    resource_prefix: str
    resource_interval_seconds: int
    ownership_prefix: str
    failure_threshold: int
    recovery_threshold: int
    minimum_owner_seconds: int
    transition_timeout_seconds: int
    target_cooldown_seconds: int
    ownership_lease_enable: bool


@dataclass(slots=True)
# All high-availability reporting, state-store, and scheduler settings.
class HASettings:
    enable: bool
    reporting: ReportingSettings
    runtime_store: RuntimeStoreSettings
    scheduler: SchedulerSettings


@dataclass(slots=True)
# One dynamic Caddy route tied to a scheduler-managed systemd unit.
class IngressRouteSettings:
    name: str
    enable: bool
    domain: str
    aliases: list[str]
    unit: str
    scheme: str
    port: int
    health_path: str
    auth: str
    authentik_host: str
    authentik_port: int
    extra_config: str


@dataclass(slots=True)
# Runtime Caddy snippet generation based on HA placement and health.
class IngressRouterSettings:
    enable: bool
    interval_seconds: int
    stale_after_seconds: int
    output_dir: str
    caddy_config_path: str
    reload_timeout_seconds: int
    reload_backoff_seconds: int
    reload_lock_path: str
    node_addresses: dict[str, str]
    routes: dict[str, IngressRouteSettings]


@dataclass(slots=True)
# Matrix trigger settings used by the long-polling listener.
class MatrixSettings:
    enable: bool
    trigger_keywords: list[str]


@dataclass(slots=True)
# HTTP webhook listener settings.
class WebhookSettings:
    enable: bool
    bind_address: str
    port: int
    ssl_cert: str
    ssl_key: str
    skip_commit_marker: str


@dataclass(slots=True)
# Typed view of `/etc/nix-cluster-runtime-config.json` for all Python daemons.
class RuntimeConfig:
    path: str
    raw: dict[str, Any]
    is_controller: bool
    controller_script: str
    hostname: str
    directories: DirectorySettings
    update: UpdateSettings
    controller: ControllerSettings
    placement: PlacementSettings
    observability: ObservabilitySettings
    local_recovery: LocalRecoverySettings
    ha: HASettings
    ingress_router: IngressRouterSettings
    matrix: MatrixSettings
    webhook: WebhookSettings

    @classmethod
    def from_path(cls, path: str | None = None) -> "RuntimeConfig":
        # Load the runtime JSON file and return the normalized config object.
        resolved = _resolve_config_path(path)
        with open(resolved, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
        return cls.from_raw(resolved, raw)

    @classmethod
    def from_raw(cls, path: str, raw: dict[str, Any]) -> "RuntimeConfig":
        # Turn the raw JSON dictionary from Nix into small typed settings objects.
        directories_raw = raw.get("directories", {})
        update_raw = raw.get("update", raw.get("commands", {}))
        controller_raw = raw.get("controller", {})
        monitor_raw = controller_raw.get("monitor", {})
        placement_raw = raw.get("placement", {})
        observability_raw = raw.get("observability", {})
        prometheus_raw = observability_raw.get("prometheus", {})
        loki_raw = observability_raw.get("loki", {})
        local_recovery_raw = raw.get("local_recovery", {})
        ha_raw = raw.get("ha", {})
        reporting_raw = ha_raw.get("reporting", {})
        runtime_store_raw = ha_raw.get("runtime_store", {})
        local_server_raw = runtime_store_raw.get("local_server", {})
        scheduler_raw = ha_raw.get("scheduler", {})
        ingress_router_raw = raw.get("ingress_router", {})
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

        placement = PlacementSettings(
            node_role=str(placement_raw.get("node_role", "worker")),
            ha_role=str(placement_raw.get("ha_role", "passive")),
            keepalived_role=str(placement_raw.get("keepalived_role", "disabled")),
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

        local_recovery = LocalRecoverySettings(
            enable=_as_bool(local_recovery_raw.get("enable"), True),
            critical_units=_as_list(local_recovery_raw.get("critical_units", ["NetworkManager.service"])),
            interval_seconds=_as_int(local_recovery_raw.get("interval_seconds"), 15),
            dry_run=_as_bool(local_recovery_raw.get("dry_run"), False),
        )

        ha = HASettings(
            enable=_as_bool(ha_raw.get("enable"), False),
            reporting=ReportingSettings(
                enable=_as_bool(reporting_raw.get("enable"), False),
                mode=str(reporting_raw.get("mode", "only")),
                services=_as_list(reporting_raw.get("services", [])),
                include_tracked_units=_as_bool(reporting_raw.get("include_tracked_units"), True),
                interval_seconds=_as_int(reporting_raw.get("interval_seconds"), 15),
                collection_deadline_seconds=_as_int(reporting_raw.get("collection_deadline_seconds"), 30),
            ),
            runtime_store=RuntimeStoreSettings(
                type=str(runtime_store_raw.get("type", "none")),
                endpoint=str(runtime_store_raw.get("endpoint", "")),
                key_prefix=str(runtime_store_raw.get("key_prefix", "/nix-cluster/health")),
                inventory_prefix=str(runtime_store_raw.get("inventory_prefix", "/nix-cluster/inventory")),
                join_prefix=str(runtime_store_raw.get("join_prefix", "/nix-cluster/join")),
                stale_after_seconds=_as_int(runtime_store_raw.get("stale_after_seconds"), 45),
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
                interval_seconds=_as_int(scheduler_raw.get("interval_seconds"), 15),
                controller_mode=str(scheduler_raw.get("controller_mode", "fixed")),
                fixed_controller_host=str(scheduler_raw.get("fixed_controller_host", "")),
                leader_key=str(scheduler_raw.get("leader_key", "/nix-cluster/scheduler/leader")),
                placement_prefix=str(scheduler_raw.get("placement_prefix", "/nix-cluster/scheduler/placement")),
                request_prefix=str(scheduler_raw.get("request_prefix", "/nix-cluster/scheduler/requests")),
                lease_ttl_seconds=_as_int(scheduler_raw.get("lease_ttl_seconds"), 45),
                default_strategy=str(scheduler_raw.get("default_strategy", "prefer-current-healthy")),
                managed_units=_as_list(scheduler_raw.get("managed_units", [])),
                app_groups={str(name): _as_list(units) for name, units in dict(scheduler_raw.get("app_groups", {})).items()},
                reconciler_enable=_as_bool(scheduler_raw.get("reconciler_enable"), False),
                reconciler_interval_seconds=_as_int(scheduler_raw.get("reconciler_interval_seconds"), 15),
                reconciler_dry_run=_as_bool(scheduler_raw.get("reconciler_dry_run"), False),
                resource_prefix=str(scheduler_raw.get("resource_prefix", "/nix-cluster/scheduler/resources")),
                resource_interval_seconds=_as_int(scheduler_raw.get("resource_interval_seconds"), 30),
                ownership_prefix=str(scheduler_raw.get("ownership_prefix", "/nix-cluster/scheduler/ownership")),
                failure_threshold=_as_int(scheduler_raw.get("failure_threshold"), 3),
                recovery_threshold=_as_int(scheduler_raw.get("recovery_threshold"), 2),
                minimum_owner_seconds=_as_int(scheduler_raw.get("minimum_owner_seconds"), 300),
                transition_timeout_seconds=_as_int(scheduler_raw.get("transition_timeout_seconds"), 120),
                target_cooldown_seconds=_as_int(scheduler_raw.get("target_cooldown_seconds"), 300),
                ownership_lease_enable=_as_bool(scheduler_raw.get("ownership_lease_enable"), False),
            ),
        )

        routes: dict[str, IngressRouteSettings] = {}
        for name, route_raw in dict(ingress_router_raw.get("routes", {})).items():
            route_name = str(name)
            if not route_name:
                continue
            routes[route_name] = IngressRouteSettings(
                name=route_name,
                enable=_as_bool(route_raw.get("enable"), True),
                domain=str(route_raw.get("domain", "")),
                aliases=_as_list(route_raw.get("aliases", [])),
                unit=str(route_raw.get("unit", "")),
                scheme=str(route_raw.get("scheme", "http")),
                port=_as_int(route_raw.get("port"), 80),
                health_path=str(route_raw.get("health_path", "/")),
                auth=str(route_raw.get("auth", "none")),
                authentik_host=str(route_raw.get("authentik_host", "127.0.0.1")),
                authentik_port=_as_int(route_raw.get("authentik_port"), 9000),
                extra_config=str(route_raw.get("extra_config", "")),
            )

        ingress_router = IngressRouterSettings(
            enable=_as_bool(ingress_router_raw.get("enable"), False),
            interval_seconds=_as_int(ingress_router_raw.get("interval_seconds"), 5),
            stale_after_seconds=_as_int(ingress_router_raw.get("stale_after_seconds"), 45),
            output_dir=str(ingress_router_raw.get("output_dir", "/run/nix-cluster/ingress/caddy.d")),
            caddy_config_path=str(ingress_router_raw.get("caddy_config_path", "/etc/caddy/caddy_config")),
            reload_timeout_seconds=_as_int(ingress_router_raw.get("reload_timeout_seconds"), 20),
            reload_backoff_seconds=_as_int(ingress_router_raw.get("reload_backoff_seconds"), 30),
            reload_lock_path=str(ingress_router_raw.get("reload_lock_path", "/run/nix-cluster/ingress/caddy.reload.lock")),
            node_addresses={str(name): str(address) for name, address in dict(ingress_router_raw.get("node_addresses", {})).items()},
            routes=routes,
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
            placement=placement,
            observability=observability,
            local_recovery=local_recovery,
            ha=ha,
            ingress_router=ingress_router,
            matrix=matrix,
            webhook=webhook,
        )

    @property
    def repo_dir(self) -> str:
        # Shortcut for the fleet checkout path.
        return self.directories.repo

    @property
    def update_commands(self) -> list[str]:
        # Shortcut for commands that run after a relevant update is accepted.
        return self.update.commands
