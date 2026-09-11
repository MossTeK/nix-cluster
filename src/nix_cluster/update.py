from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Sequence

from .config import RuntimeConfig
from .core import ProcessRunner, configure_logging

logger = configure_logging("nix-cluster-update")
UPDATE_LOCK = threading.Lock()
PENDING_LOCK = threading.Lock()
PENDING_TRIGGER_ID: str | None = None


# Run the GitOps update pipeline for one node. Matrix and webhook code both
# end up here, and this class owns the careful sequence of fetch, diff,
# optional controller work, reset, and rebuild.
class UpdateManager:
    __slots__ = ("config_path", "runtime_config", "hostname", "runner")

    def __init__(self, config_path: str):
        # Load runtime settings and prepare a command runner for Git/Nix/systemd calls.
        self.config_path = config_path
        self.runtime_config = RuntimeConfig.from_path(config_path)
        self.hostname = socket.gethostname()
        self.runner = ProcessRunner(logger)

    @property
    def branch_ref(self) -> str:
        # Git ref this node treats as the desired fleet state.
        return self.runtime_config.update.branch_ref

    @property
    def remote_name(self) -> str:
        # Git remote fetched before comparing or resetting the fleet checkout.
        return self.runtime_config.update.remote_name

    def _run_command(self, cmd: Sequence[str], cwd: str, stage: str) -> str:
        # Run a command in the fleet repo and wrap its logs with a named stage.
        command_str = " ".join(cmd)
        logger.info("%s START: %s", stage, command_str)
        result = self.runner.run(cmd, cwd=cwd, check=True, capture_output=True)
        logger.info("%s SUCCESS: %s", stage, command_str)
        return (result.stdout or "").strip()

    def _get_changed_files(self, repo_dir: str) -> list[str]:
        # List files that differ between the current checkout and desired branch.
        try:
            output = self._run_command(
                ["git", "diff", "--name-only", "HEAD", self.branch_ref],
                cwd=repo_dir,
                stage="GIT-DIFF",
            )
            return output.splitlines() if output else []
        except Exception:
            return []

    def _get_changed_files_between(self, repo_dir: str, old_ref: str, new_ref: str) -> list[str]:
        # List files changed while a reset advanced the local checkout.
        if old_ref == new_ref:
            return []
        try:
            output = self._run_command(
                ["git", "diff", "--name-only", old_ref, new_ref],
                cwd=repo_dir,
                stage="GIT-DIFF-RESET-ADVANCE",
            )
            return output.splitlines() if output else []
        except Exception:
            return []

    def _rev_parse(self, repo_dir: str, ref: str, stage: str) -> str:
        # Resolve a Git ref to the exact commit id used in later comparisons.
        return self._run_command(["git", "rev-parse", ref], cwd=repo_dir, stage=stage).strip()

    def _should_rebuild(self, changed_files: list[str]) -> bool:
        # Decide whether changed paths affect this node enough to rebuild.
        if not changed_files:
            return False

        relevant_paths = self.runtime_config.update.relevant_paths or [
            f"nodes/{self.hostname}/",
            "groups/",
            "apps/",
            "modules/",
            "deployments.json",
            "secrets/",
            "scripts/",
            "flake.nix",
            "flake.lock",
        ]

        for changed_file in changed_files:
            if changed_file == "deployments.json":
                logger.info("CONTROLLER-ONLY CHANGE DETECTED: %s", changed_file)
                continue
            if any(changed_file.startswith(path) for path in relevant_paths):
                logger.info("RELEVANT CHANGE DETECTED: %s", changed_file)
                return True
        return False

    def _write_controller_script(self, controller_script: str) -> str:
        # Materialize the Nix-provided controller hook as an executable shell script.
        runtime_dir = Path(self.runtime_config.directories.controller_script_dir)
        runtime_dir.mkdir(parents=True, exist_ok=True)
        fd, script_path = tempfile.mkstemp(
            prefix="nix-cluster-controller-",
            suffix=".sh",
            dir=runtime_dir,
            text=True,
        )
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(controller_script.replace("\r", ""))
        os.chmod(script_path, 0o755)
        return script_path

    def _fetch(self, repo_dir: str, stage: str) -> None:
        # Fetch the configured Git remote.
        self._run_command(["git", "fetch", self.remote_name], cwd=repo_dir, stage=stage)

    def _reset(self, repo_dir: str, stage: str) -> None:
        # Force the local checkout to match the configured desired branch ref.
        self._run_command(["git", "reset", "--hard", self.branch_ref], cwd=repo_dir, stage=stage)

    def _switch_in_progress(self, repo_dir: str) -> bool:
        # Avoid starting a second NixOS switch while one is already running.
        checks = [
            ["systemctl", "is-active", "--quiet", "nixos-rebuild-switch-to-configuration.service"],
            ["pgrep", "-f", "switch-to-configuration switch"],
        ]
        for command in checks:
            result = self.runner.run(command, cwd=repo_dir, check=False, capture_output=True)
            if result.returncode == 0:
                logger.warning("REBUILD BLOCKED: existing switch-to-configuration is still running")
                return True
        return False

    def _systemd_unit_main_pid(self, unit: str, repo_dir: str) -> int:
        output = self._run_command(
            ["systemctl", "show", unit, "--property=MainPID", "--value"],
            cwd=repo_dir,
            stage=f"REFRESH-PID-{unit}",
        )
        try:
            return int(output.strip() or "0")
        except ValueError:
            return 0

    def _verify_unit_mount_paths(self, unit: str, paths: Sequence[str], repo_dir: str) -> None:
        if not paths:
            return

        pid = self._systemd_unit_main_pid(unit, repo_dir)
        if pid <= 0:
            raise RuntimeError(f"{unit} has no running MainPID after post-update refresh")

        for path in paths:
            output = self._run_command(
                [
                    "sudo",
                    "-n",
                    "nsenter",
                    "-t",
                    str(pid),
                    "-m",
                    "--",
                    "findmnt",
                    "--target",
                    path,
                    "--output",
                    "TARGET,SOURCE,FSTYPE",
                    "--noheadings",
                ],
                cwd=repo_dir,
                stage=f"REFRESH-MOUNT-{unit}",
            )
            if not output:
                raise RuntimeError(f"{unit} path {path} is not mounted in the service namespace")
            if "deleted" in output:
                raise RuntimeError(f"{unit} path {path} is mounted from a deleted source: {output}")
            logger.info("post_update_refresh_mount_ok unit=%s path=%s mount=%s", unit, path, output)

    def _verify_unit_required_paths(self, unit: str, paths: Sequence[str], repo_dir: str) -> None:
        if not paths:
            return

        pid = self._systemd_unit_main_pid(unit, repo_dir)
        if pid <= 0:
            raise RuntimeError(f"{unit} has no running MainPID after post-update refresh")

        for path in paths:
            self._run_command(
                [
                    "sudo",
                    "-n",
                    "nsenter",
                    "-t",
                    str(pid),
                    "-m",
                    "--",
                    "test",
                    "-e",
                    path,
                ],
                cwd=repo_dir,
                stage=f"REFRESH-PATH-{unit}",
            )

    def _refresh_post_update_units(self, repo_dir: str) -> None:
        refresh = self.runtime_config.post_update_refresh
        if not refresh.enable or not refresh.units:
            return

        for unit_config in refresh.units:
            unit = unit_config.unit
            try:
                if unit_config.restart:
                    logger.info("post_update_refresh_restart unit=%s", unit)
                    self._run_command(
                        ["sudo", "-n", "systemctl", "restart", unit],
                        cwd=repo_dir,
                        stage=f"REFRESH-RESTART-{unit}",
                    )
                self._verify_unit_mount_paths(unit, unit_config.verify_paths, repo_dir)
                self._verify_unit_required_paths(unit, unit_config.required_paths, repo_dir)
                logger.info("post_update_refresh_success unit=%s", unit)
            except Exception as error:
                logger.error("post_update_refresh_failed unit=%s error=%s", unit, error)
                raise

    def _fleet_hostnames(self, repo_dir: str) -> list[str]:
        # Discover fleet node names from `nodes/`, falling back to this node.
        nodes_dir = Path(repo_dir) / "nodes"
        if nodes_dir.is_dir():
            hostnames = sorted(child.name for child in nodes_dir.iterdir() if child.is_dir())
            if hostnames:
                return hostnames

        runtime_hostname = self.runtime_config.hostname or self.hostname
        return [runtime_hostname]

    def _read_secret_generation_config(self, repo_dir: str, target_host: str) -> dict[str, object]:
        # Evaluate one node's declared generated-secret requests from Nix.
        output = self._run_command(
            [
                "nix",
                "eval",
                "--json",
                f'.#nixosConfigurations."{target_host}".config.services."nix-cluster".secretGeneration',
            ],
            cwd=repo_dir,
            stage=f"SECRET-EVAL-{target_host}",
        )
        return json.loads(output) if output else {}

    def _collect_secret_requests(self, repo_dir: str) -> dict[str, dict[str, dict[str, object]]]:
        # Merge generated-secret requests from every node by target SOPS file.
        requests_by_file: dict[str, dict[str, dict[str, object]]] = {}

        for target_host in self._fleet_hostnames(repo_dir):
            secret_config = self._read_secret_generation_config(repo_dir, target_host)
            if not secret_config or not secret_config.get("enable", True):
                continue

            sops_file = str(secret_config.get("sopsFile", "secrets/secrets.yaml"))
            host_requests = secret_config.get("requests", {})
            if not isinstance(host_requests, dict):
                continue

            file_requests = requests_by_file.setdefault(sops_file, {})
            for secret_name, raw_spec in host_requests.items():
                if not isinstance(raw_spec, dict):
                    continue

                request_spec = {
                    "generator": str(raw_spec.get("generator", "base64")),
                    "length": int(raw_spec.get("length", 48)),
                }
                existing_spec = file_requests.get(secret_name)
                if existing_spec is not None and existing_spec != request_spec:
                    raise RuntimeError(
                        f"conflicting secret generation settings for {secret_name} in {sops_file}: {existing_spec} vs {request_spec}"
                    )
                file_requests[secret_name] = request_spec

        return requests_by_file

    def _sync_declared_secrets(self, repo_dir: str) -> bool:
        # Ensure all declared generated secrets exist and report whether Git changed.
        requests_by_file = self._collect_secret_requests(repo_dir)
        if not requests_by_file:
            return False

        repo_head_before = self._run_command(["git", "rev-parse", "HEAD"], cwd=repo_dir, stage="SECRET-HEAD-BEFORE")

        for sops_file, requests in sorted(requests_by_file.items()):
            if not requests:
                continue

            command = [
                "nix-cluster-secret-ensure",
                "--json",
                "--git-sync",
                "--quiet",
                "--sops-file",
                sops_file,
            ]
            command.extend(
                f"{name}={spec['generator']}:{spec['length']}" for name, spec in sorted(requests.items())
            )
            self._run_command(command, cwd=repo_dir, stage=f"SECRET-SYNC-{sops_file}")

        repo_head_after = self._run_command(["git", "rev-parse", "HEAD"], cwd=repo_dir, stage="SECRET-HEAD-AFTER")
        return repo_head_before != repo_head_after

    def _queue_update_trigger(self, trigger_id: str) -> str:
        # Remember the newest trigger when an update is already running.
        global PENDING_TRIGGER_ID
        with PENDING_LOCK:
            PENDING_TRIGGER_ID = trigger_id
        logger.info("NIX-CLUSTER UPDATE ALREADY RUNNING. QUEUING TRIGGER: %s", trigger_id)
        return "QUEUED: update already in progress"

    def _pop_queued_update_trigger(self) -> str | None:
        # Take the queued trigger, if any, so the active updater can run it next.
        global PENDING_TRIGGER_ID
        with PENDING_LOCK:
            trigger_id = PENDING_TRIGGER_ID
            PENDING_TRIGGER_ID = None
        return trigger_id

    def _perform_update_once(self, trigger_id: str) -> str:
        # Run one full fetch/diff/controller/rebuild cycle for a single trigger.
        logger.info("NIX-CLUSTER UPDATE SEQUENCE INITIATED: %s", trigger_id)
        repo_dir = self.runtime_config.repo_dir
        is_controller = self.runtime_config.is_controller
        controller_script = self.runtime_config.controller_script

        try:
            self._fetch(repo_dir, "GIT-FETCH")
            changed_files = self._get_changed_files(repo_dir)
            needs_rebuild = self._should_rebuild(changed_files)
            secrets_changed = False

            if is_controller and controller_script:
                logger.info("NODE IS CONTROLLER. SYNCING REPO BEFORE CONTROLLER SCRIPT...")
                self._reset(repo_dir, "GIT-RESET-PRE")
                logger.info("EXECUTING CONTROLLER SCRIPT...")
                script_path = self._write_controller_script(controller_script)
                try:
                    self._run_command(["bash", "-c", script_path], cwd=repo_dir, stage="CONTROLLER-HOOK")
                except subprocess.CalledProcessError as error:
                    logger.warning("CONTROLLER-HOOK FAILED (non-fatal, continuing with rebuild): %s", error)
                self._fetch(repo_dir, "GIT-FETCH-POST")

            if is_controller:
                head_before_reset = self._rev_parse(repo_dir, "HEAD", "GIT-HEAD-BEFORE-SECRET-SYNC")
                self._reset(repo_dir, "GIT-RESET-SECRET-SYNC")
                head_after_reset = self._rev_parse(repo_dir, "HEAD", "GIT-HEAD-AFTER-SECRET-SYNC")
                reset_advanced_files = self._get_changed_files_between(repo_dir, head_before_reset, head_after_reset)
                secrets_changed = self._sync_declared_secrets(repo_dir)
                if secrets_changed:
                    self._fetch(repo_dir, "GIT-FETCH-SECRET-POST")
                changed_files = self._get_changed_files(repo_dir)
                needs_rebuild = (
                    needs_rebuild
                    or secrets_changed
                    or self._should_rebuild(reset_advanced_files)
                    or self._should_rebuild(changed_files)
                )
            else:
                logger.info(
                    "NODE IS WORKER. PAUSING %ss FOR CONTROLLER TO PROVISION SECRETS...",
                    self.runtime_config.update.worker_wait_seconds,
                )
                time.sleep(self.runtime_config.update.worker_wait_seconds)
                self._fetch(repo_dir, "GIT-FETCH-POST")
                changed_files = self._get_changed_files(repo_dir)
                needs_rebuild = self._should_rebuild(changed_files)

            if not needs_rebuild:
                self._reset(repo_dir, "GIT-RESET")
                self._refresh_post_update_units(repo_dir)
                logger.info("NO RELEVANT CHANGES FOUND. RESETTING REPO.")
                return "SKIPPED"

            if self._switch_in_progress(repo_dir):
                return "SKIPPED: switch-to-configuration already running"

            self._reset(repo_dir, "GIT-RESET")
            output_log = [
                self._run_command(["bash", "-c", command.replace("\r", "")], cwd=repo_dir, stage="REBUILD")
                for command in self.runtime_config.update.commands
            ]
            self._refresh_post_update_units(repo_dir)
            logger.info("NIX-CLUSTER REBUILD TASK COMPLETED: %s", trigger_id)
            return "\n".join(filter(None, output_log)).strip()
        except Exception as error:
            logger.error("NIX-CLUSTER UPDATE PIPELINE FAILED: %s", error)
            return f"FAILURE: {error}"

    def perform_update(self, trigger_id: str) -> str:
        # Public update entry point with locking and one-slot follow-up queueing.
        if not UPDATE_LOCK.acquire(blocking=False):
            return self._queue_update_trigger(trigger_id)

        current_trigger = trigger_id
        results = []
        try:
            while True:
                results.append(self._perform_update_once(current_trigger))
                queued_trigger = self._pop_queued_update_trigger()
                if queued_trigger is None:
                    return "\n".join(filter(None, results)).strip()
                logger.info("NIX-CLUSTER QUEUED UPDATE STARTING: %s", queued_trigger)
                current_trigger = queued_trigger
        finally:
            UPDATE_LOCK.release()

    def run_boot_sequence(self) -> None:
        # Fetch and reset at daemon startup so the local checkout begins current.
        repo_dir = self.runtime_config.repo_dir
        logger.info("INITIALIZING BOOT SYNCHRONIZATION...")
        try:
            self._fetch(repo_dir, "BOOT")
            self._reset(repo_dir, "BOOT")
            self._refresh_post_update_units(repo_dir)
        except Exception as error:
            logger.error("BOOT SYNC FAILED: %s", error)
