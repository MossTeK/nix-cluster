from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from typing import Any

from .config import RuntimeConfig
from .runtime import EtcdClient

CLUSTER_STATE_KEY = "/nix-cluster/cluster-state"
DEFAULT_REQUEST_TTL_SECONDS = 600


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _dedupe(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


@dataclass(frozen=True)
class AppInfo:
    name: str
    units: list[str]
    domains: list[str]
    active_owner: str | None
    desired_owner: str | None
    target_owner: str | None
    phase: str
    healthy: bool
    candidates: list[str]

    def to_json(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "units": self.units,
            "domains": self.domains,
            "active_owner": self.active_owner,
            "desired_owner": self.desired_owner,
            "target_owner": self.target_owner,
            "phase": self.phase,
            "healthy": self.healthy,
            "candidates": self.candidates,
        }


def load_placements(config: RuntimeConfig, etcd: EtcdClient) -> dict[str, dict[str, Any]]:
    prefix = config.ha.scheduler.placement_prefix.rstrip("/")
    return {
        key.removeprefix(prefix + "/"): payload
        for key, payload in etcd.get_prefix(prefix).items()
        if key.removeprefix(prefix + "/")
    }


def load_cluster_state(etcd: EtcdClient) -> dict[str, Any]:
    entry = etcd.get_key(CLUSTER_STATE_KEY)
    if not entry or not isinstance(entry.get("value"), dict):
        return {}
    return entry["value"]


def route_domains_by_unit(config: RuntimeConfig) -> dict[str, list[str]]:
    domains: dict[str, list[str]] = {}
    for route in config.ingress_router.routes.values():
        if not route.enable or not route.unit:
            continue
        values = [route.domain, *route.aliases]
        domains.setdefault(route.unit, []).extend(value for value in values if value)
    return {unit: _dedupe(values) for unit, values in domains.items()}


def app_units(config: RuntimeConfig) -> dict[str, list[str]]:
    groups = {name: _dedupe(units) for name, units in config.ha.scheduler.app_groups.items() if units}
    grouped_units = {unit for units in groups.values() for unit in units}
    for unit in config.ha.scheduler.managed_units:
        if unit not in grouped_units:
            groups.setdefault(unit.removesuffix(".service"), [unit])
    return groups


def summarize_app(
    name: str,
    units: list[str],
    domains_by_unit: dict[str, list[str]],
    placements: dict[str, dict[str, Any]],
    cluster_state: dict[str, Any],
) -> AppInfo:
    unit_states = [placements.get(unit, {}) for unit in units]
    active = _first_same([state.get("active_owner") or state.get("desired_owner") for state in unit_states])
    desired = _first_same([state.get("desired_owner") for state in unit_states])
    target = _first_same([state.get("target_owner") for state in unit_states])
    phases = {str(state.get("phase") or "unknown") for state in unit_states if state}
    phase = phases.pop() if len(phases) == 1 else ("unknown" if not phases else "mixed")
    domains = _dedupe([domain for unit in units for domain in domains_by_unit.get(unit, [])])
    candidates = _dedupe([
        candidate
        for unit in units
        for candidate in dict(cluster_state.get("services", {})).get(unit, {}).get("candidate_nodes", [])
    ])
    healthy = bool(active) and all(
        bool(dict(dict(cluster_state.get("services", {})).get(unit, {}).get("reports", {})).get(str(active), {}).get("healthy"))
        for unit in units
    )
    return AppInfo(name, units, domains, str(active) if active else None, str(desired) if desired else None, str(target) if target else None, phase, healthy, candidates)


def _first_same(values: list[Any]) -> Any:
    normalized = [value for value in values if value]
    if not normalized:
        return None
    first = normalized[0]
    if all(value == first for value in normalized):
        return first
    return "mixed"


def build_inventory(config: RuntimeConfig, etcd: EtcdClient) -> list[AppInfo]:
    placements = load_placements(config, etcd)
    cluster_state = load_cluster_state(etcd)
    domains_by_unit = route_domains_by_unit(config)
    return [
        summarize_app(name, units, domains_by_unit, placements, cluster_state)
        for name, units in sorted(app_units(config).items())
    ]


def validate_move(config: RuntimeConfig, app: str, node: str, etcd: EtcdClient, now: int | None = None) -> tuple[list[str], list[str]]:
    now = int(time.time()) if now is None else now
    groups = app_units(config)
    units = groups.get(app)
    if not units:
        return [], [f"unknown app: {app}"]

    cluster_state = load_cluster_state(etcd)
    services = dict(cluster_state.get("services", {}))
    resources = dict(cluster_state.get("resources", {}))
    stale_after = max(1, config.ha.runtime_store.stale_after_seconds)
    resource_stale_after = max(stale_after, config.ha.scheduler.resource_interval_seconds * 3)
    errors: list[str] = []

    resource = dict(resources.get(node, {}))
    if not resource:
        errors.append(f"target node has no resource report: {node}")
    elif now - _safe_int(resource.get("observed_at")) > resource_stale_after:
        errors.append(f"target node resource report is stale: {node}")
    elif not resource.get("schedulable"):
        errors.append(f"target node is not schedulable: {node}")

    for unit in units:
        report = dict(dict(services.get(unit, {})).get("reports", {}).get(node, {}))
        if not report:
            errors.append(f"target node does not report unit: {unit}")
            continue
        if now - _safe_int(report.get("observed_at")) > stale_after:
            errors.append(f"target node report is stale for unit: {unit}")
        if report.get("load_state") != "loaded":
            errors.append(f"target node has unit unloaded: {unit}")

    return units, errors


def move_request_payload(app: str, unit: str, node: str, reason: str, now: int, ttl: int = DEFAULT_REQUEST_TTL_SECONDS) -> dict[str, Any]:
    return {
        "app": app,
        "unit": unit,
        "target_owner": node,
        "reason": reason,
        "status": "pending",
        "requested_at": now,
        "expires_at": now + ttl,
    }


def request_move(config: RuntimeConfig, etcd: EtcdClient, app: str, node: str, reason: str, dry_run: bool = False) -> int:
    units, errors = validate_move(config, app, node, etcd)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 2

    if dry_run:
        print(f"would move {app} to {node}: {', '.join(units)}")
        return 0

    now = int(time.time())
    prefix = config.ha.scheduler.request_prefix.rstrip("/")
    for unit in units:
        etcd.put_json(f"{prefix}/{unit}", move_request_payload(app, unit, node, reason, now))
    print(f"requested move {app} -> {node}: {', '.join(units)}")
    return 0


def print_apps(apps: list[AppInfo], json_output: bool) -> None:
    if json_output:
        print(json.dumps([app.to_json() for app in apps], indent=2, sort_keys=True))
        return
    print(f"{'APP':<28} {'DOMAIN':<34} {'ACTIVE':<10} {'DESIRED':<10} {'TARGET':<10} {'PHASE':<14} HEALTH")
    for app in apps:
        domain = ",".join(app.domains) if app.domains else "-"
        print(f"{app.name:<28} {domain:<34} {app.active_owner or '-':<10} {app.desired_owner or '-':<10} {app.target_owner or '-':<10} {app.phase:<14} {'ok' if app.healthy else 'bad'}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="nix-cluster")
    parser.add_argument("-a", "--app", help="App to move")
    parser.add_argument("-n", "--node", help="Target node for --app")
    parser.add_argument("--config", help="Runtime config path")
    subparsers = parser.add_subparsers(dest="command")

    apps = subparsers.add_parser("apps", help="List nix-cluster apps")
    apps.add_argument("--json", action="store_true")

    move = subparsers.add_parser("move", help="Request an app handoff")
    move.add_argument("--app", required=True)
    move.add_argument("--node", required=True)
    move.add_argument("--reason", default="operator requested move")
    move.add_argument("--dry-run", action="store_true")
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    config = RuntimeConfig.from_path(args.config)
    if config.ha.runtime_store.type != "etcd" or not config.ha.runtime_store.endpoint:
        raise SystemExit("nix-cluster CLI requires an etcd runtime store")
    etcd = EtcdClient(config.ha.runtime_store.endpoint)

    if args.app and args.node:
        raise SystemExit(request_move(config, etcd, args.app, args.node, "operator requested move", False))
    if args.command == "apps":
        print_apps(build_inventory(config, etcd), args.json)
        return
    if args.command == "move":
        raise SystemExit(request_move(config, etcd, args.app, args.node, args.reason, args.dry_run))
    parser.print_help()


if __name__ == "__main__":
    main()
