from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
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
    service_states = dict(cluster_state.get("services", {}))
    healthy = bool(active) and all(
        bool(service.get("usable")) if "usable" in service else bool(dict(service.get("reports", {})).get(str(active), {}).get("healthy"))
        for service in (dict(service_states.get(unit, {})) for unit in units)
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


def resolve_units(config: RuntimeConfig, selector: str) -> list[str]:
    groups = app_units(config)
    if selector in groups:
        return groups[selector]
    if selector in config.ha.scheduler.managed_units:
        return [selector]
    return []


def validate_move(config: RuntimeConfig, app: str, node: str, etcd: EtcdClient, now: int | None = None) -> tuple[list[str], list[str]]:
    now = int(time.time()) if now is None else now
    units = resolve_units(config, app)
    if not units:
        return [], [f"unknown app: {app}"]

    cluster_state = load_cluster_state(etcd)
    scheduler = dict(cluster_state.get("scheduler", {}))
    leader = dict(scheduler.get("leader", {}))
    if not scheduler.get("is_leader") or not leader.get("hostname"):
        errors = ["no current controller leader is publishing scheduler state"]
    else:
        errors = []
    services = dict(cluster_state.get("services", {}))
    resources = dict(cluster_state.get("resources", {}))
    stale_after = max(1, config.ha.runtime_store.stale_after_seconds)
    resource_stale_after = max(stale_after, config.ha.scheduler.resource_interval_seconds * 3)

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


def move_request_payload(app: str, unit: str, node: str, reason: str, now: int, ttl: int = DEFAULT_REQUEST_TTL_SECONDS, request_id: str = "") -> dict[str, Any]:
    return {
        "app": app,
        "unit": unit,
        "target_owner": node,
        "reason": reason,
        "status": "pending",
        "request_id": request_id or str(uuid.uuid4()),
        "requested_at": now,
        "expires_at": now + ttl,
    }


def request_move(config: RuntimeConfig, etcd: EtcdClient, app: str, node: str, reason: str, dry_run: bool = False, wait: bool = False, timeout: int = 300) -> int:
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
    request_id = str(uuid.uuid4())
    for unit in units:
        etcd.put_json(f"{prefix}/{unit}", move_request_payload(app, unit, node, reason, now, timeout, request_id))
    print(f"requested move {app} -> {node}: {', '.join(units)}")
    if wait:
        return wait_for_move(config, etcd, units, node, request_id, timeout)
    return 0


def wait_for_move(config: RuntimeConfig, etcd: EtcdClient, units: list[str], node: str, request_id: str, timeout: int) -> int:
    deadline = time.monotonic() + max(1, timeout)
    prefix = config.ha.scheduler.request_prefix.rstrip("/")
    terminal_failures = {"failed", "rejected", "expired"}
    while time.monotonic() < deadline:
        completed = True
        for unit in units:
            entry = etcd.get_key(f"{prefix}/{unit}")
            payload = dict(entry.get("value", {})) if entry else {}
            if payload.get("request_id") != request_id:
                print(f"move request was superseded for {unit}", file=sys.stderr)
                return 3
            status = str(payload.get("status", "pending"))
            if status in terminal_failures:
                print(f"move failed for {unit}: {payload.get('failure') or payload.get('reason') or status}", file=sys.stderr)
                return 3
            completed = completed and status == "completed"
        if completed:
            placements = load_placements(config, etcd)
            if all(
                placements.get(unit, {}).get("phase") == "stable"
                and placements.get(unit, {}).get("active_owner") == node
                for unit in units
            ):
                print(f"move completed on {node}: {', '.join(units)}")
                return 0
        time.sleep(1)
    print(f"timed out waiting for move after {timeout}s", file=sys.stderr)
    return 4


def print_placement_status(config: RuntimeConfig, etcd: EtcdClient, unit: str | None, json_output: bool) -> int:
    placements = load_placements(config, etcd)
    cluster_state = load_cluster_state(etcd)
    service_states = dict(cluster_state.get("services", {}))
    if unit:
        units = resolve_units(config, unit)
        if not units:
            print(f"unknown unit or app: {unit}", file=sys.stderr)
            return 2
        placements = {name: placements.get(name, {}) for name in units}
    if json_output:
        print(json.dumps({
            name: {**state, **{key: value for key, value in dict(service_states.get(name, {})).items() if key in {
                "usable", "usable_reason", "routable", "route_reason", "lease_valid", "lease_reason", "health_fresh", "has_route",
            }}}
            for name, state in placements.items()
        }, indent=2, sort_keys=True))
    else:
        print(f"{'UNIT':<36} {'ACTIVE':<12} {'DESIRED':<12} {'PHASE':<16} {'USABLE':<8} REASON")
        for name, state in sorted(placements.items()):
            service = dict(service_states.get(name, {}))
            usable = "yes" if service.get("usable") else "no"
            reason = service.get("usable_reason") or service.get("route_reason") or service.get("lease_reason") or "-"
            print(f"{name:<36} {state.get('active_owner') or '-':<12} {state.get('desired_owner') or '-':<12} {state.get('phase') or 'unknown':<16} {usable:<8} {reason}")
    return 0


def print_apps(apps: list[AppInfo], json_output: bool) -> None:
    if json_output:
        print(json.dumps([app.to_json() for app in apps], indent=2, sort_keys=True))
        return
    print(f"{'APP':<28} {'DOMAIN':<34} {'ACTIVE':<10} {'DESIRED':<10} {'TARGET':<10} {'PHASE':<14} USABLE")
    for app in apps:
        domain = ",".join(app.domains) if app.domains else "-"
        print(f"{app.name:<28} {domain:<34} {app.active_owner or '-':<10} {app.desired_owner or '-':<10} {app.target_owner or '-':<10} {app.phase:<14} {'yes' if app.healthy else 'no'}")


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

    placement = subparsers.add_parser("placement", help="Inspect or safely move scheduler placements")
    placement_commands = placement.add_subparsers(dest="placement_command", required=True)
    status = placement_commands.add_parser("status", help="Show placement state")
    status.add_argument("unit", nargs="?")
    status.add_argument("--json", action="store_true")
    placement_move = placement_commands.add_parser("move", help="Request a fenced one-shot move")
    placement_move.add_argument("unit")
    placement_move.add_argument("node")
    placement_move.add_argument("--wait", action="store_true")
    placement_move.add_argument("--timeout", type=int, default=300)
    placement_move.add_argument("--reason", default="operator requested move")
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
    if args.command == "placement" and args.placement_command == "status":
        raise SystemExit(print_placement_status(config, etcd, args.unit, args.json))
    if args.command == "placement" and args.placement_command == "move":
        raise SystemExit(request_move(config, etcd, args.unit, args.node, args.reason, False, args.wait, args.timeout))
    parser.print_help()


if __name__ == "__main__":
    main()
