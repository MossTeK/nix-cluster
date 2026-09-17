from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any

DEFAULT_CONFIG_PATH = "/etc/nix-cluster-runtime-config.json"
LEGACY_CONFIG_PATH = "/etc/nops-runtime-config.json"
SCHEDULER_DENIED_UNITS = {
    "NetworkManager.service",
    "caddy.service",
    "etcd.service",
    "keepalived.service",
    "nix-cluster-runtime-store.service",
    "nix-cluster.service",
    "sshd.service",
    "ssh.service",
}


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


def _default_ownership_lease_enable(scheduler_raw: dict[str, Any]) -> bool:
    # Legacy runtime JSON did not carry this field. Managed units are stateful
    # scheduler targets, so fail closed into exclusive leases when omitted.
    return bool(_as_list(scheduler_raw.get("managed_units", [])) or _enabled_workloads(scheduler_raw))


def _enabled_workloads(scheduler_raw: dict[str, Any]) -> dict[str, dict[str, Any]]:
    workloads: dict[str, dict[str, Any]] = {}
    for name, raw in dict(scheduler_raw.get("workloads", {})).items():
        payload = dict(raw) if isinstance(raw, dict) else {}
        if not _as_bool(payload.get("enable"), True):
            continue
        units = _as_list(payload.get("units", []))
        if units:
            workloads[str(name)] = {
                "units": units,
                "group": str(payload.get("group", "") or ""),
            }
    return workloads


def _dedupe(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


def scheduler_unit_sets(scheduler_raw: dict[str, Any]) -> tuple[list[str], list[str], dict[str, list[str]], dict[str, dict[str, Any]]]:
    workloads = _enabled_workloads(scheduler_raw)
    requested = _dedupe(
        _as_list(scheduler_raw.get("managed_units", []))
        + [unit for workload in workloads.values() for unit in workload["units"]]
    )
    managed = [unit for unit in requested if unit not in SCHEDULER_DENIED_UNITS]
    rejected = [unit for unit in requested if unit in SCHEDULER_DENIED_UNITS]
    app_groups = {str(name): _as_list(units) for name, units in dict(scheduler_raw.get("app_groups", {})).items()}
    for name, workload in workloads.items():
        group = workload.get("group") or name
        app_groups[group] = _dedupe(app_groups.get(group, []) + workload["units"])
    return managed, rejected, app_groups, workloads


# Read an integer config value, with a default for omitted fields.
def _as_int(raw: Any, default: int) -> int:
    if raw is None:
        return default
    return int(raw)


def _as_float(raw: Any, default: float) -> float:
    if raw is None:
        return default
    return float(raw)

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
class PostUpdateRefreshUnitSettings:
    unit: str
    restart: bool
    verify_paths: list[str]
    required_paths: list[str]


@dataclass(slots=True)
class PostUpdateRefreshSettings:
    enable: bool
    units: list[PostUpdateRefreshUnitSettings]


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
class UnitPolicySettings:
    preferred_nodes: list[str]
    minimum_memory_available_bytes: int
    maximum_load_per_cpu: float
    estimated_memory_bytes: int
    estimated_cpu: float
    automatic_rebalance: bool
    rebalance_observation_threshold: int
    minimum_memory_advantage_bytes: int
    minimum_load_advantage_percent: float
    require_healthy_state_storage: bool


@dataclass(slots=True)
class StorageHealthSettings:
    enable: bool
    command: list[str]
    required_mounts: list[str]
    probe_path: str
    timeout_seconds: int
    healthy_observation_threshold: int


@dataclass(slots=True)
# How controller nodes choose service owners and how workers apply that choice.
class SchedulerSettings:
    enable: bool
    interval_seconds: int
    controller_mode: str
    fixed_controller_host: str
    leader_key: str
    placement_prefix: str
    lease_ttl_seconds: int
    default_strategy: str
    managed_units: list[str]
    rejected_managed_units: list[str]
    workloads: dict[str, dict[str, Any]]
    app_groups: dict[str, list[str]]
    reconciler_enable: bool
    reconciler_interval_seconds: int
    reconciler_dry_run: bool
    resource_prefix: str
    resource_interval_seconds: int
    node_schedulable: bool
    storage_health: StorageHealthSettings
    ownership_prefix: str
    failure_threshold: int
    recovery_threshold: int
    minimum_owner_seconds: int
    transition_timeout_seconds: int
    target_cooldown_seconds: int
    ownership_lease_enable: bool
    lease_renewal_seconds: int
    request_prefix: str
    unit_policies: dict[str, UnitPolicySettings]


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
class AppContractSettings:
    name: str
    enable: bool
    units: list[str]
    primary_unit: str
    port: int
    domain: str
    route_name: str
    shared_state_required: bool
    shared_state_root: str
    shared_state_mounts: list[str]
    placement_ha: bool
    preferred_nodes: list[str]
    require_healthy_state_storage: bool


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
    post_update_refresh: PostUpdateRefreshSettings
    controller: ControllerSettings
    placement: PlacementSettings
    observability: ObservabilitySettings
    local_recovery: LocalRecoverySettings
    ha: HASettings
    ingress_router: IngressRouterSettings
    app_contracts: dict[str, AppContractSettings]
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
        post_update_refresh_raw = raw.get("post_update_refresh", {})
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
        managed_units, rejected_managed_units, app_groups, workloads = scheduler_unit_sets(dict(scheduler_raw))
        ingress_router_raw = raw.get("ingress_router", {})
        app_contracts_raw = raw.get("app_contracts", {})
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

        post_update_refresh = PostUpdateRefreshSettings(
            enable=_as_bool(post_update_refresh_raw.get("enable"), True),
            units=[
                PostUpdateRefreshUnitSettings(
                    unit=str(unit_raw.get("unit", "")),
                    restart=_as_bool(unit_raw.get("restart"), True),
                    verify_paths=_as_list(unit_raw.get("verify_paths", [])),
                    required_paths=_as_list(unit_raw.get("required_paths", [])),
                )
                for unit_raw in post_update_refresh_raw.get("units", [])
                if isinstance(unit_raw, dict) and str(unit_raw.get("unit", ""))
            ],
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
                lease_ttl_seconds=_as_int(scheduler_raw.get("lease_ttl_seconds"), 90),
                default_strategy=str(scheduler_raw.get("default_strategy", "prefer-current-healthy")),
                managed_units=managed_units,
                rejected_managed_units=rejected_managed_units,
                workloads=workloads,
                app_groups=app_groups,
                reconciler_enable=_as_bool(scheduler_raw.get("reconciler_enable"), False),
                reconciler_interval_seconds=_as_int(scheduler_raw.get("reconciler_interval_seconds"), 15),
                reconciler_dry_run=_as_bool(scheduler_raw.get("reconciler_dry_run"), False),
                resource_prefix=str(scheduler_raw.get("resource_prefix", "/nix-cluster/scheduler/resources")),
                resource_interval_seconds=_as_int(scheduler_raw.get("resource_interval_seconds"), 30),
                node_schedulable=_as_bool(scheduler_raw.get("node_schedulable"), True),
                storage_health=StorageHealthSettings(
                    enable=_as_bool(dict(scheduler_raw.get("storage_health", {})).get("enable"), False),
                    command=_as_list(dict(scheduler_raw.get("storage_health", {})).get("command", [])),
                    required_mounts=_as_list(dict(scheduler_raw.get("storage_health", {})).get("required_mounts", [])),
                    probe_path=str(dict(scheduler_raw.get("storage_health", {})).get("probe_path", "/var/lib/nix-cluster")),
                    timeout_seconds=_as_int(dict(scheduler_raw.get("storage_health", {})).get("timeout_seconds"), 10),
                    healthy_observation_threshold=_as_int(dict(scheduler_raw.get("storage_health", {})).get("healthy_observation_threshold"), 3),
                ),
                ownership_prefix=str(scheduler_raw.get("ownership_prefix", "/nix-cluster/scheduler/ownership")),
                failure_threshold=_as_int(scheduler_raw.get("failure_threshold"), 3),
                recovery_threshold=_as_int(scheduler_raw.get("recovery_threshold"), 2),
                minimum_owner_seconds=_as_int(scheduler_raw.get("minimum_owner_seconds"), 300),
                transition_timeout_seconds=_as_int(scheduler_raw.get("transition_timeout_seconds"), 120),
                target_cooldown_seconds=_as_int(scheduler_raw.get("target_cooldown_seconds"), 300),
                ownership_lease_enable=_as_bool(
                    scheduler_raw.get("ownership_lease_enable"),
                    _default_ownership_lease_enable(scheduler_raw),
                ),
                lease_renewal_seconds=_as_int(scheduler_raw.get("lease_renewal_seconds"), 15),
                unit_policies={
                    str(unit): UnitPolicySettings(
                        preferred_nodes=_as_list(policy.get("preferred_nodes", [])),
                        minimum_memory_available_bytes=_as_int(policy.get("minimum_memory_available_bytes"), 0),
                        maximum_load_per_cpu=_as_float(policy.get("maximum_load_per_cpu"), 0.0),
                        estimated_memory_bytes=_as_int(policy.get("estimated_memory_bytes"), 0),
                        estimated_cpu=_as_float(policy.get("estimated_cpu"), 0.0),
                        automatic_rebalance=_as_bool(policy.get("automatic_rebalance"), False),
                        rebalance_observation_threshold=_as_int(policy.get("rebalance_observation_threshold"), 3),
                        minimum_memory_advantage_bytes=_as_int(policy.get("minimum_memory_advantage_bytes"), 0),
                        minimum_load_advantage_percent=_as_float(policy.get("minimum_load_advantage_percent"), 30.0),
                        require_healthy_state_storage=_as_bool(policy.get("require_healthy_state_storage"), True),
                    )
                    for unit, policy in dict(scheduler_raw.get("unit_policies", {})).items()
                },
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

        app_contracts: dict[str, AppContractSettings] = {}
        for name, contract_raw in dict(app_contracts_raw or {}).items():
            contract_name = str(name)
            if not contract_name or not isinstance(contract_raw, dict):
                continue
            shared_raw = dict(contract_raw.get("shared_state", {}))
            placement_contract_raw = dict(contract_raw.get("placement", {}))
            app_contracts[contract_name] = AppContractSettings(
                name=contract_name,
                enable=_as_bool(contract_raw.get("enable"), False),
                units=_as_list(contract_raw.get("units", [])),
                primary_unit=str(contract_raw.get("primary_unit", "")),
                port=_as_int(contract_raw.get("port"), 0),
                domain=str(contract_raw.get("domain", "")),
                route_name=str(contract_raw.get("route_name", contract_name)),
                shared_state_required=_as_bool(shared_raw.get("required"), True),
                shared_state_root=str(shared_raw.get("root", "")),
                shared_state_mounts=_as_list(shared_raw.get("mounts", [])),
                placement_ha=_as_bool(placement_contract_raw.get("ha"), True),
                preferred_nodes=_as_list(placement_contract_raw.get("preferred_nodes", [])),
                require_healthy_state_storage=_as_bool(placement_contract_raw.get("require_healthy_state_storage"), True),
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
            post_update_refresh=post_update_refresh,
            controller=controller,
            placement=placement,
            observability=observability,
            local_recovery=local_recovery,
            ha=ha,
            ingress_router=ingress_router,
            app_contracts=app_contracts,
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
