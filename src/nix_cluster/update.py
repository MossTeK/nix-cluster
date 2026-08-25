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


class UpdateManager:
    __slots__ = ("config_path", "runtime_config", "hostname", "runner")

    def __init__(self, config_path: str):
        self.config_path = config_path
        self.runtime_config = RuntimeConfig.from_path(config_path)
        self.hostname = socket.gethostname()
        self.runner = ProcessRunner(logger)

    @property
    def branch_ref(self) -> str:
        return self.runtime_config.update.branch_ref

    @property
    def remote_name(self) -> str:
        return self.runtime_config.update.remote_name

    def _run_command(self, cmd: Sequence[str], cwd: str, stage: str) -> str:
        command_str = " ".join(cmd)
        logger.info("%s START: %s", stage, command_str)
        result = self.runner.run(cmd, cwd=cwd, check=True, capture_output=True)
        logger.info("%s SUCCESS: %s", stage, command_str)
        return (result.stdout or "").strip()

    def _get_changed_files(self, repo_dir: str) -> list[str]:
        try:
            output = self._run_command(
                ["git", "diff", "--name-only", "HEAD", self.branch_ref],
                cwd=repo_dir,
                stage="GIT-DIFF",
            )
            return output.splitlines() if output else []
        except Exception:
            return []

    def _should_rebuild(self, changed_files: list[str]) -> bool:
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
        self._run_command(["git", "fetch", self.remote_name], cwd=repo_dir, stage=stage)

    def _reset(self, repo_dir: str, stage: str) -> None:
        self._run_command(["git", "reset", "--hard", self.branch_ref], cwd=repo_dir, stage=stage)

    def _switch_in_progress(self, repo_dir: str) -> bool:
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

    def _fleet_hostnames(self, repo_dir: str) -> list[str]:
        nodes_dir = Path(repo_dir) / "nodes"
        if nodes_dir.is_dir():
            hostnames = sorted(child.name for child in nodes_dir.iterdir() if child.is_dir())
            if hostnames:
                return hostnames

        runtime_hostname = self.runtime_config.hostname or self.hostname
        return [runtime_hostname]

    def _read_secret_generation_config(self, repo_dir: str, target_host: str) -> dict[str, object]:
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
        global PENDING_TRIGGER_ID
        with PENDING_LOCK:
            PENDING_TRIGGER_ID = trigger_id
        logger.info("NIX-CLUSTER UPDATE ALREADY RUNNING. QUEUING TRIGGER: %s", trigger_id)
        return "QUEUED: update already in progress"

    def _pop_queued_update_trigger(self) -> str | None:
        global PENDING_TRIGGER_ID
        with PENDING_LOCK:
            trigger_id = PENDING_TRIGGER_ID
            PENDING_TRIGGER_ID = None
        return trigger_id

    def _perform_update_once(self, trigger_id: str) -> str:
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
                self._reset(repo_dir, "GIT-RESET-SECRET-SYNC")
                secrets_changed = self._sync_declared_secrets(repo_dir)
                if secrets_changed:
                    self._fetch(repo_dir, "GIT-FETCH-SECRET-POST")
                changed_files = self._get_changed_files(repo_dir)
                needs_rebuild = needs_rebuild or secrets_changed or self._should_rebuild(changed_files)
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
                logger.info("NO RELEVANT CHANGES FOUND. RESETTING REPO.")
                return "SKIPPED"

            if self._switch_in_progress(repo_dir):
                return "SKIPPED: switch-to-configuration already running"

            self._reset(repo_dir, "GIT-RESET")
            output_log = [
                self._run_command(["bash", "-c", command.replace("\r", "")], cwd=repo_dir, stage="REBUILD")
                for command in self.runtime_config.update.commands
            ]
            logger.info("NIX-CLUSTER REBUILD TASK COMPLETED: %s", trigger_id)
            return "\n".join(filter(None, output_log)).strip()
        except Exception as error:
            logger.error("NIX-CLUSTER UPDATE PIPELINE FAILED: %s", error)
            return f"FAILURE: {error}"

    def perform_update(self, trigger_id: str) -> str:
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
        repo_dir = self.runtime_config.repo_dir
        logger.info("INITIALIZING BOOT SYNCHRONIZATION...")
        try:
            self._fetch(repo_dir, "BOOT")
            self._reset(repo_dir, "BOOT")
        except Exception as error:
            logger.error("BOOT SYNC FAILED: %s", error)
