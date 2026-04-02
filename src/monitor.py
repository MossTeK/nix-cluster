import base64
import json
import logging
import os
import socket
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Dict, Tuple

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("nix-cluster-monitor")

CONFIG_PATH = os.environ.get("NOPS_CONFIG_PATH", "/etc/nops-runtime-config.json")


def load_config() -> Dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=path.parent, encoding="utf-8") as handle:
        handle.write(content)
        temp_path = Path(handle.name)
    temp_path.replace(path)


def atomic_write_json(path: Path, payload: Dict) -> None:
    atomic_write_text(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")


def base64_text(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def prefix_range_end(prefix: bytes) -> bytes:
    buffer = bytearray(prefix)
    for index in range(len(buffer) - 1, -1, -1):
        if buffer[index] != 0xFF:
            buffer[index] += 1
            return bytes(buffer[: index + 1])
    return prefix + b"\x00"


def get_etcd_prefix(endpoint: str, prefix: str) -> Dict[str, Dict]:
    prefix_bytes = prefix.encode("utf-8")
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/v3/kv/range",
        data=json.dumps(
            {
                "key": base64_text(prefix_bytes),
                "range_end": base64_text(prefix_range_end(prefix_bytes)),
            }
        ).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=4) as response:
        payload = json.loads(response.read().decode("utf-8"))

    items: Dict[str, Dict] = {}
    for entry in payload.get("kvs", []):
        key = base64.b64decode(entry["key"]).decode("utf-8")
        value = json.loads(base64.b64decode(entry["value"]).decode("utf-8"))
        items[key] = value
    return items


def service_and_host_from_key(prefix: str, key: str) -> Tuple[str, str]:
    trimmed = key.removeprefix(prefix.rstrip("/") + "/")
    host, _, unit = trimmed.partition("/")
    return host, unit


def build_cluster_metrics(cluster_state: Dict) -> str:
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

    controller = cluster_state.get("controller", "unknown")
    lines.extend(
        [
            "# HELP nix_cluster_monitor_timestamp_seconds Unix timestamp of the most recent controller aggregation pass.",
            "# TYPE nix_cluster_monitor_timestamp_seconds gauge",
            f'nix_cluster_monitor_timestamp_seconds{{host="{controller}"}} {int(time.time())}',
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    config = load_config()
    ha_cfg = config.get("ha", {})
    runtime_store = ha_cfg.get("runtime_store", {})
    scheduler_cfg = ha_cfg.get("scheduler", {})
    if not config.get("is_controller", False):
        logger.info("monitor disabled on non-controller node")
        return
    if not (ha_cfg.get("enable") and scheduler_cfg.get("enable")):
        logger.info("controller scheduler disabled")
        return
    if runtime_store.get("type") != "etcd" or not runtime_store.get("endpoint"):
        logger.info("controller scheduler requires an etcd runtime store endpoint")
        return

    endpoint = runtime_store["endpoint"]
    prefix = runtime_store.get("key_prefix", "/nix-cluster/health")
    stale_after = max(1, int(runtime_store.get("stale_after_seconds", 15)))
    interval = max(1, int(scheduler_cfg.get("interval_seconds", 5)))
    controller = socket.gethostname()
    state_root = Path(config.get("directories", {}).get("state", "/var/lib/nops"))
    metrics_root = Path(config.get("directories", {}).get("metrics", "/var/lib/nops/metrics"))
    cluster_state_path = state_root / "ha" / "cluster-state.json"
    metrics_path = metrics_root / "cluster-state.prom"
    previous_targets: Dict[str, str] = {}

    logger.info("starting controller monitor on %s", controller)
    while True:
        try:
            now = int(time.time())
            records = get_etcd_prefix(endpoint, prefix)
            services: Dict[str, Dict] = {}

            for key, payload in records.items():
                host, service = service_and_host_from_key(prefix, key)
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
                prior = previous_targets.get(service)
                healthy_nodes = payload["healthy_nodes"]
                target = prior if prior in healthy_nodes else (healthy_nodes[0] if healthy_nodes else None)
                if prior != target:
                    logger.info(
                        "service_target_change service=%s previous=%s current=%s healthy_nodes=%s",
                        service,
                        prior or "",
                        target or "",
                        ",".join(healthy_nodes),
                    )
                payload["recommended_target"] = target
                previous_targets[service] = target or ""

                if not healthy_nodes:
                    logger.warning(
                        "service_unavailable service=%s unhealthy_nodes=%s stale_nodes=%s",
                        service,
                        ",".join(payload["unhealthy_nodes"]),
                        ",".join(payload["stale_nodes"]),
                    )

            cluster_state = {
                "controller": controller,
                "observed_at": now,
                "runtime_store": endpoint,
                "services": services,
            }
            atomic_write_json(cluster_state_path, cluster_state)
            atomic_write_text(metrics_path, build_cluster_metrics(cluster_state))
        except urllib.error.URLError as error:
            logger.warning("runtime_store_unreachable endpoint=%s error=%s", endpoint, error)
        except Exception as error:  # noqa: BLE001
            logger.exception("monitor_loop_failed: %s", error)

        time.sleep(interval)


if __name__ == "__main__":
    main()
