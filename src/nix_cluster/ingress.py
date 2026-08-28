from __future__ import annotations

import argparse
import fcntl
import hashlib
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


# Check whether the scheduler's chosen owner has a fresh healthy report.
def _healthy_owner(cluster_state: dict[str, Any], unit: str, owner: str, now: int, stale_after: int) -> bool:
    observed_at = _safe_int(cluster_state.get("observed_at"))
    if not observed_at or now - observed_at > stale_after:
        return False

    service = dict(cluster_state.get("services", {})).get(unit, {})
    reports = dict(service.get("reports", {}))
    report = dict(reports.get(owner, {}))
    if not report:
        return False
    if now - _safe_int(report.get("observed_at")) > stale_after:
        return False
    return bool(report.get("healthy"))


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

    owner = str(placement.get("active_owner") or placement.get("desired_owner") or "")
    if not owner:
        return None, "missing desired owner"

    address = node_addresses.get(owner)
    if not address:
        return None, "missing owner address"

    if not _healthy_owner(cluster_state, route.unit, owner, now, stale_after):
        return None, "owner not healthy"

    if "active_owner" in placement and ownership_records is not None:
        ownership = ownership_records.get(route.unit, {})
        if ownership.get("host") != owner or _safe_int(ownership.get("generation")) != _safe_int(placement.get("generation")):
            return None, "owner lease not valid"

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

    def write_snippets(self, snippets: dict[str, str]) -> bool:
        # Write changed Caddy snippets and report whether any file changed.
        output_dir = Path(self.router.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        changed = False
        for name, content in snippets.items():
            path = output_dir / f"{name}.caddy"
            current = path.read_text(encoding="utf-8") if path.exists() else ""
            if current == content:
                continue
            temporary = path.with_suffix(".caddy.tmp")
            temporary.write_text(content, encoding="utf-8")
            os.replace(temporary, path)
            changed = True
        return changed

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
            snippets[name] = render_route_snippet(route, target, reason)

        digest = hashlib.sha256("".join(f"{name}\0{content}\0" for name, content in sorted(snippets.items())).encode("utf-8")).hexdigest()
        changed = self.write_snippets(snippets)
        if changed or digest != self.last_digest:
            self.last_digest = digest
            if changed:
                self.reload_caddy()
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
