from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import logging
import os
import subprocess
import time
from pathlib import Path
from typing import Any

from .config import IngressRouteSettings, RuntimeConfig
from .runtime import EtcdClient

CLUSTER_STATE_KEY = "/nix-cluster/cluster-state"


# Parse route timestamps and ports without letting bad data crash routing.
def _safe_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


# Escape text before embedding it in generated Caddy snippets.
def _caddy_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


# Return a fail-closed Caddy response for routes without a healthy backend.
def _route_unavailable(reason: str) -> str:
    return f'respond "nix-cluster route unavailable: {_caddy_escape(reason)}" 503\n'


def route_status_for_unit(
    unit: str,
    placements: dict[str, dict[str, Any]],
    cluster_state: dict[str, Any],
    node_addresses: dict[str, str],
    now: int,
    stale_after: int,
    ownership_records: dict[str, dict[str, Any]] | None = None,
    *,
    has_route: bool = True,
) -> dict[str, Any]:
    """Compute whether a service is actually usable by ingress.

    A systemd-active unit is not enough. Dynamic ingress is allowed only when
    the controller has fresh health, a non-stale placement, an address, and a
    matching ownership lease for the active generation.
    """
    status: dict[str, Any] = {
        "has_route": has_route,
        "routable": False,
        "route_reason": "not evaluated",
        "lease_valid": False,
        "lease_reason": "not evaluated",
        "health_fresh": False,
        "usable": False,
        "usable_reason": "not evaluated",
    }

    observed_at = _safe_int(cluster_state.get("observed_at"))
    if not observed_at or now - observed_at > stale_after:
        status.update({
            "route_reason": "cluster state stale",
            "lease_reason": "not checked",
            "usable_reason": "cluster state stale",
        })
        return status

    placement = placements.get(unit)
    if not placement:
        status.update({
            "route_reason": "missing placement",
            "lease_reason": "not checked",
            "usable_reason": "missing placement",
        })
        return status
    if now - _safe_int(placement.get("updated_at")) > stale_after:
        status.update({
            "route_reason": "stale placement",
            "lease_reason": "not checked",
            "usable_reason": "stale placement",
        })
        return status

    phase = str(placement.get("phase") or "")
    if phase and phase != "stable":
        status.update({
            "route_reason": f"placement {phase}",
            "lease_reason": "not checked",
            "usable_reason": f"placement {phase}",
        })
        return status

    owner = str(placement.get("active_owner") or "")
    if not owner:
        status.update({
            "route_reason": "missing active owner",
            "lease_reason": "not checked",
            "usable_reason": "missing active owner",
        })
        return status
    status["owner"] = owner

    service = dict(cluster_state.get("services", {})).get(unit, {})
    reports = dict(service.get("reports", {}))
    report = dict(reports.get(owner, {}))
    if not report:
        status.update({
            "route_reason": "owner report missing",
            "lease_reason": "not checked",
            "usable_reason": "owner report missing",
        })
        return status
    if now - _safe_int(report.get("observed_at")) > stale_after:
        status.update({
            "route_reason": "owner report stale",
            "lease_reason": "not checked",
            "usable_reason": "owner report stale",
        })
        return status
    status["health_fresh"] = True
    if not report.get("healthy"):
        status.update({
            "route_reason": "owner unhealthy",
            "lease_reason": "not checked",
            "usable_reason": "owner unhealthy",
        })
        return status

    if "active_owner" in placement and ownership_records is not None:
        ownership = ownership_records.get(unit, {})
        if not ownership:
            status.update({
                "route_reason": "ownership lease missing",
                "lease_reason": "ownership lease missing",
                "usable_reason": "ownership lease missing",
            })
            return status
        if ownership.get("host") != owner:
            status.update({
                "route_reason": "ownership lease owner mismatch",
                "lease_reason": "ownership lease owner mismatch",
                "usable_reason": "ownership lease owner mismatch",
            })
            return status
        if _safe_int(ownership.get("generation")) != _safe_int(placement.get("generation")):
            status.update({
                "route_reason": "ownership lease generation mismatch",
                "lease_reason": "ownership lease generation mismatch",
                "usable_reason": "ownership lease generation mismatch",
            })
            return status

    status.update({"lease_valid": True, "lease_reason": "ownership lease valid"})
    address = node_addresses.get(owner)
    if has_route and not address:
        status.update({
            "route_reason": "missing owner address",
            "usable_reason": "missing owner address",
        })
        return status
    if not has_route:
        status.update({
            "routable": False,
            "route_reason": "no route configured",
            "usable": True,
            "usable_reason": "service healthy with valid ownership",
        })
        return status
    status.update({"routable": True, "route_reason": "route available", "usable": True, "usable_reason": "route available"})
    return status


def target_for_route(
    route: IngressRouteSettings,
    placements: dict[str, dict[str, Any]],
    cluster_state: dict[str, Any],
    node_addresses: dict[str, str],
    now: int,
    stale_after: int,
    ownership_records: dict[str, dict[str, Any]] | None = None,
) -> tuple[str | None, str | None]:
    # Choose the backend URL for a route, or explain why it must stay closed.
    if not route.enable:
        return None, "disabled"
    if not route.unit:
        return None, "missing unit"

    placement = placements.get(route.unit)
    if not placement:
        return None, "missing placement"
    if now - _safe_int(placement.get("updated_at")) > stale_after:
        return None, "stale placement"

    if str(placement.get("phase") or "") != "stable":
        return None, f"placement {placement.get('phase') or 'not stable'}"

    owner = str(placement.get("active_owner") or "")
    if not owner:
        return None, "missing active owner"

    status = route_status_for_unit(route.unit, placements, cluster_state, node_addresses, now, stale_after, ownership_records)
    if not status.get("routable"):
        return None, str(status.get("route_reason") or status.get("usable_reason") or "no backend")
    address = node_addresses.get(owner)
    return f"{route.scheme}://{address}:{route.port}", None


# Render the Caddy snippet for one dynamic route.
def render_route_snippet(route: IngressRouteSettings, target: str | None, reason: str | None) -> str:
    if not target:
        return _route_unavailable(reason or "no backend")

    health_path = route.health_path or "/"
    proxy_block = f"""reverse_proxy {{
  to {target}
  lb_policy first
  health_uri {health_path}
  health_interval 10s
  fail_duration 30s
  header_up Host {{host}}
  header_up X-Forwarded-Host {{host}}
  header_up X-Forwarded-Proto https
  header_down -X-Frame-Options
{route.extra_config.rstrip()}
}}
"""

    if route.auth == "authentik":
        upstream = f"{route.authentik_host}:{route.authentik_port}"
        return f"""route {{
  reverse_proxy /outpost.goauthentik.io/* {upstream} {{
    header_up Host {{host}}
    header_up X-Forwarded-Host {{host}}
    header_up X-Forwarded-Proto https
  }}

  forward_auth {upstream} {{
    uri /outpost.goauthentik.io/auth/caddy
    header_up Host {{host}}
    header_up X-Forwarded-Host {{host}}
    header_up X-Forwarded-Proto https
    copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Entitlements X-Authentik-Email X-Authentik-Name
  }}

  {proxy_block.rstrip()}
}}
"""

    return proxy_block


# Generate and reload Caddy route snippets from scheduler placement in etcd.
class IngressRouter:
    def __init__(self, config: RuntimeConfig):
        # Keep the runtime config and connect to the configured etcd endpoint.
        self.config = config
        self.router = config.ingress_router
        self.logger = logging.getLogger("nix-cluster.ingress")
        self.etcd = EtcdClient(config.ha.runtime_store.endpoint)
        self.last_digest = ""
        self.reload_backoff_until = 0.0
        self.last_route_states: dict[str, tuple[str | None, str]] = {}

    def load_placements(self) -> dict[str, dict[str, Any]]:
        # Read scheduler placement records keyed by managed systemd unit.
        prefix = self.config.ha.scheduler.placement_prefix.rstrip("/")
        records = self.etcd.get_prefix(prefix) if prefix else {}
        placements: dict[str, dict[str, Any]] = {}
        for key, payload in records.items():
            unit = key.removeprefix(prefix + "/")
            if unit:
                placements[unit] = payload
        return placements

    def load_cluster_state(self) -> dict[str, Any]:
        # Read the aggregated cluster health document from etcd.
        entry = self.etcd.get_key(CLUSTER_STATE_KEY)
        if not entry or not isinstance(entry.get("value"), dict):
            return {}
        return entry["value"]

    def load_ownership(self) -> dict[str, dict[str, Any]]:
        prefix = self.config.ha.scheduler.ownership_prefix.rstrip("/")
        records = self.etcd.get_prefix(prefix) if prefix else {}
        return {key.removeprefix(prefix + "/"): payload for key, payload in records.items()}

    def write_route_status(self, statuses: list[dict[str, Any]]) -> None:
        status_path = Path(self.router.status_path)
        status_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = status_path.with_suffix(status_path.suffix + ".tmp")
        temporary.write_text(json.dumps({"routes": statuses}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, status_path)

    def write_snippets(self, snippets: dict[str, str]) -> tuple[bool, dict[Path, str | None]]:
        # Write changed Caddy snippets and return originals for rollback.
        output_dir = Path(self.router.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        changed = False
        originals: dict[Path, str | None] = {}
        for name, content in snippets.items():
            path = output_dir / f"{name}.caddy"
            current = path.read_text(encoding="utf-8") if path.exists() else ""
            if current == content:
                continue
            originals[path] = current if path.exists() else None
            temporary = path.with_suffix(".caddy.tmp")
            temporary.write_text(content, encoding="utf-8")
            os.replace(temporary, path)
            changed = True
        return changed, originals

    def restore_snippets(self, originals: dict[Path, str | None]) -> None:
        for path, content in originals.items():
            if content is None:
                path.unlink(missing_ok=True)
                continue
            temporary = path.with_suffix(".caddy.rollback.tmp")
            temporary.write_text(content, encoding="utf-8")
            os.replace(temporary, path)

    def validate_caddy(self) -> tuple[bool, str]:
        command = [self.router.caddy_command, "validate", "--config", self.router.caddy_config_path, "--adapter", "caddyfile"]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=10, check=False)
        except subprocess.TimeoutExpired:
            return False, "caddy validation timed out"
        except FileNotFoundError:
            return False, f"caddy command not found: {self.router.caddy_command}"
        if result.returncode == 0:
            return True, ""
        return False, (result.stderr or result.stdout or "caddy validation failed").strip()

    def reload_caddy(self) -> None:
        # Reload Caddy once snippets change, with a lock and failure backoff.
        now = time.monotonic()
        if now < self.reload_backoff_until:
            self.logger.warning("skipping caddy reload while previous failure is in backoff")
            return

        timeout = max(1, self.router.reload_timeout_seconds)
        active = subprocess.run(
            ["systemctl", "is-active", "--quiet", "caddy.service"],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        if active.returncode != 0:
            self.logger.warning("skipping caddy reload because caddy.service is not active")
            return

        lock_path = Path(self.router.reload_lock_path)
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("w", encoding="utf-8") as lock_file:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.logger.warning("skipping caddy reload because another reload is still running")
                return

            command = ["sudo", "-n", "systemctl", "reload", "caddy.service"]
            try:
                result = subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)
            except subprocess.TimeoutExpired:
                self.reload_backoff_until = time.monotonic() + max(1, self.router.reload_backoff_seconds)
                self.logger.error("timed out reloading caddy after %ss; backing off", timeout)
                return

            if result.returncode == 0:
                self.logger.info("caddy reloaded after ingress route update")
                return

            self.reload_backoff_until = time.monotonic() + max(1, self.router.reload_backoff_seconds)
            self.logger.error("failed to reload caddy: %s", (result.stderr or result.stdout).strip())

    def reconcile_once(self) -> bool:
        # Run one placement-to-Caddy pass and reload when rendered output changes.
        now = int(time.time())
        placements = self.load_placements()
        cluster_state = self.load_cluster_state()
        ownership_records = self.load_ownership() if self.config.ha.scheduler.ownership_lease_enable else None
        snippets: dict[str, str] = {}
        route_statuses: list[dict[str, Any]] = []
        for name, route in sorted(self.router.routes.items()):
            target, reason = target_for_route(
                route,
                placements,
                cluster_state,
                self.router.node_addresses,
                now,
                self.router.stale_after_seconds,
                ownership_records,
            )
            status = route_status_for_unit(
                route.unit,
                placements,
                cluster_state,
                self.router.node_addresses,
                now,
                self.router.stale_after_seconds,
                ownership_records,
            )
            owner = status.get("owner")
            route_reason = str(reason or status.get("route_reason") or "")
            route_statuses.append({
                "route_name": name,
                "domain": route.domain,
                "unit": route.unit,
                "owner": owner,
                "target": target,
                "routable": bool(target),
                "reason": "route available" if target else route_reason,
                "generated_at": now,
                "placement_phase": str(placements.get(route.unit, {}).get("phase") or ""),
                "lease_valid": bool(status.get("lease_valid")),
                "health_fresh": bool(status.get("health_fresh")),
            })
            state_key = (target, "route available" if target else route_reason)
            if self.last_route_states.get(name) != state_key:
                self.logger.info(
                    "route_state_change route=%s unit=%s target=%s reason=%s",
                    name,
                    route.unit,
                    target or "",
                    state_key[1],
                )
                self.last_route_states[name] = state_key
            snippets[name] = render_route_snippet(route, target, reason)

        digest = hashlib.sha256("".join(f"{name}\0{content}\0" for name, content in sorted(snippets.items())).encode("utf-8")).hexdigest()
        changed, originals = self.write_snippets(snippets)
        if changed or digest != self.last_digest:
            if changed:
                valid, validation_reason = self.validate_caddy()
                if not valid:
                    self.restore_snippets(originals)
                    for status in route_statuses:
                        status["validation"] = "failed"
                        status["validation_reason"] = validation_reason
                    self.write_route_status(route_statuses)
                    self.logger.error("caddy validation failed after ingress route update: %s", validation_reason)
                    return False
                for status in route_statuses:
                    status["validation"] = "ok"
                self.write_route_status(route_statuses)
                self.last_digest = digest
                self.reload_caddy()
            else:
                self.write_route_status(route_statuses)
                self.last_digest = digest
        else:
            self.write_route_status(route_statuses)
        return changed

    def run(self) -> None:
        # Loop forever when ingress routing is enabled and an etcd store exists.
        if not self.router.enable:
            self.logger.info("ingress router disabled")
            return
        if self.config.ha.runtime_store.type != "etcd" or not self.config.ha.runtime_store.endpoint:
            self.logger.info("ingress router requires an etcd runtime store endpoint")
            return
        while True:
            try:
                self.reconcile_once()
            except Exception:
                self.logger.exception("ingress router reconciliation failed")
            time.sleep(max(1, self.router.interval_seconds))


# CLI entry point used by the `nix-cluster-ingress-router` wrapper.
def main() -> None:
    parser = argparse.ArgumentParser(description="nix-cluster dynamic ingress router")
    parser.add_argument("--config", default=None)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    IngressRouter(RuntimeConfig.from_path(args.config)).run()


if __name__ == "__main__":
    main()
