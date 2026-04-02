import base64
import json
import logging
import os
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Dict, List, Set

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("nix-cluster-reporter")

ACTIVE_STATES = {"active", "activating", "reloading"}
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


def run_command(command: List[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"command failed: {' '.join(command)}")
    return result.stdout


def list_all_service_units() -> Set[str]:
    output = run_command([
        "systemctl",
        "list-unit-files",
        "--type=service",
        "--plain",
        "--no-legend",
        "--no-pager",
    ])
    units = set()
    for line in output.splitlines():
        parts = line.split()
        if parts and parts[0].endswith(".service"):
            units.add(parts[0])
    return units


def collect_unit_status(unit: str, hostname: str) -> Dict:
    output = run_command([
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
    ])
    values: Dict[str, str] = {}
    for line in output.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value

    active_state = values.get("ActiveState", "unknown")
    payload = {
        "host": hostname,
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
    return payload


def base64_text(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def put_etcd_json(endpoint: str, key: str, payload: Dict) -> None:
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/v3/kv/put",
        data=json.dumps(
            {
                "key": base64_text(key.encode("utf-8")),
                "value": base64_text(json.dumps(payload, sort_keys=True).encode("utf-8")),
            }
        ).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=3):
        return


def build_metric_lines(hostname: str, services: Dict[str, Dict]) -> str:
    lines = [
        "# HELP nix_cluster_service_healthy Whether a reported systemd unit is healthy.",
        "# TYPE nix_cluster_service_healthy gauge",
    ]
    for unit, payload in sorted(services.items()):
        healthy = "1" if payload["healthy"] else "0"
        active_state = payload["active_state"].replace('"', '\\"')
        sub_state = payload["sub_state"].replace('"', '\\"')
        lines.append(
            f'nix_cluster_service_healthy{{host="{hostname}",service="{unit}",active_state="{active_state}",sub_state="{sub_state}"}} {healthy}'
        )

    lines.extend(
        [
            "# HELP nix_cluster_report_timestamp_seconds Unix timestamp of the most recent reporter pass.",
            "# TYPE nix_cluster_report_timestamp_seconds gauge",
            f'nix_cluster_report_timestamp_seconds{{host="{hostname}"}} {int(time.time())}',
        ]
    )
    return "\n".join(lines) + "\n"


def selected_units(config: Dict, all_units: Set[str]) -> List[str]:
    ha_cfg = config.get("ha", {})
    reporting_cfg = ha_cfg.get("reporting", {})
    tracked_units = set(config.get("observability", {}).get("tracked_units", []))
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


def main() -> None:
    config = load_config()
    ha_cfg = config.get("ha", {})
    reporting_cfg = ha_cfg.get("reporting", {})
    if not (ha_cfg.get("enable") and reporting_cfg.get("enable")):
        logger.info("service reporting disabled")
        return

    hostname = socket.gethostname()
    state_root = Path(config.get("directories", {}).get("state", "/var/lib/nops"))
    metrics_root = Path(config.get("directories", {}).get("metrics", "/var/lib/nops/metrics"))
    snapshot_path = state_root / "ha" / "service-health.json"
    metrics_path = metrics_root / "service-health.prom"
    previous_states: Dict[str, bool] = {}
    runtime_store = ha_cfg.get("runtime_store", {})
    runtime_enabled = runtime_store.get("type") == "etcd" and runtime_store.get("endpoint")
    key_prefix = runtime_store.get("key_prefix", "/nix-cluster/health").rstrip("/")
    interval = max(1, int(reporting_cfg.get("interval_seconds", 5)))

    logger.info("starting service reporter on %s", hostname)
    while True:
        try:
            units = selected_units(config, list_all_service_units())
            services: Dict[str, Dict] = {}
            for unit in units:
                payload = collect_unit_status(unit, hostname)
                services[unit] = payload

                prior = previous_states.get(unit)
                current = payload["healthy"]
                if prior is None or prior != current:
                    logger.info(
                        "service_state_change host=%s unit=%s healthy=%s active_state=%s sub_state=%s",
                        hostname,
                        unit,
                        str(current).lower(),
                        payload["active_state"],
                        payload["sub_state"],
                    )
                previous_states[unit] = current

                if runtime_enabled:
                    put_etcd_json(runtime_store["endpoint"], f"{key_prefix}/{hostname}/{unit}", payload)

            snapshot = {
                "host": hostname,
                "observed_at": int(time.time()),
                "services": services,
            }
            atomic_write_json(snapshot_path, snapshot)
            atomic_write_text(metrics_path, build_metric_lines(hostname, services))
        except urllib.error.URLError as error:
            logger.warning("runtime_store_unreachable endpoint=%s error=%s", runtime_store.get("endpoint", ""), error)
        except Exception as error:  # noqa: BLE001
            logger.exception("reporter_loop_failed: %s", error)

        time.sleep(interval)


if __name__ == "__main__":
    main()
