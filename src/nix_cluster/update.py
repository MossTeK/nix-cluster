from __future__ import annotations

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

logger = configure_logging("nops-update")
UPDATE_LOCK = threading.Lock()


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
            "modules/",
            "deployments.json",
            "secrets/",
            "scripts/",
            "flake.nix",
            "flake.lock",
        ]

        for changed_file in changed_files:
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

    def perform_update(self, trigger_id: str) -> str:
        if not UPDATE_LOCK.acquire(blocking=False):
            logger.info("NOPS UPDATE ALREADY RUNNING. SKIPPING TRIGGER: %s", trigger_id)
            return "SKIPPED: update already in progress"

        logger.info("NOPS UPDATE SEQUENCE INITIATED: %s", trigger_id)
        repo_dir = self.runtime_config.repo_dir
        is_controller = self.runtime_config.is_controller
        controller_script = self.runtime_config.controller_script

        try:
            self._fetch(repo_dir, "GIT-FETCH")
            changed_files = self._get_changed_files(repo_dir)
            needs_rebuild = self._should_rebuild(changed_files)

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
                needs_rebuild = True
            elif not is_controller:
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

            self._reset(repo_dir, "GIT-RESET")
            output_log = [
                self._run_command(["bash", "-c", command.replace("\r", "")], cwd=repo_dir, stage="REBUILD")
                for command in self.runtime_config.update.commands
            ]
            logger.info("NOPS REBUILD TASK COMPLETED: %s", trigger_id)
            return "\n".join(filter(None, output_log)).strip()
        except Exception as error:
            logger.error("NOPS UPDATE PIPELINE FAILED: %s", error)
            return f"FAILURE: {error}"
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
