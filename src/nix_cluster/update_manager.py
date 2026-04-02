from __future__ import annotations

import os
import socket
import subprocess
import threading
import time
from pathlib import Path
from typing import List

from .logging_utils import configure_logging
from .process_runner import ProcessRunner
from .runtime_config import RuntimeConfig

logger = configure_logging("nops-update")
UPDATE_LOCK = threading.Lock()


class UpdateManager:
    __slots__ = ("config_path", "runtime_config", "hostname", "runner")

    def __init__(self, config_path: str):
        self.config_path = config_path
        self.runtime_config = RuntimeConfig.from_path(config_path)
        self.hostname = socket.gethostname()
        self.runner = ProcessRunner(logger)

    def _run_command(self, cmd: List[str], cwd: str, stage: str) -> str:
        command_str = " ".join(cmd)
        logger.info("%s START: %s", stage, command_str)
        result = self.runner.run(cmd, cwd=cwd, check=True, capture_output=True)

        if result.returncode != 0:
            logger.error("%s FAILED WITH CODE %s", stage, result.returncode)
            raise subprocess.CalledProcessError(
                result.returncode,
                cmd,
                output=result.stdout,
                stderr=result.stderr,
            )

        logger.info("%s SUCCESS: %s", stage, command_str)
        return (result.stdout or "").strip()

    def _get_changed_files(self, repo_dir: str) -> List[str]:
        try:
            output = self._run_command(
                ["git", "diff", "--name-only", "HEAD", "origin/main"],
                cwd=repo_dir,
                stage="GIT-DIFF",
            )
            return output.splitlines() if output else []
        except Exception:
            return []

    def _should_rebuild(self, changed_files: List[str]) -> bool:
        if not changed_files:
            return False

        relevant_paths = [
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
        script_path = "/tmp/nops_controller.sh"
        Path(script_path).write_text(controller_script.replace("\r", ""), encoding="utf-8", newline="\n")
        os.chmod(script_path, 0o755)
        return script_path

    def perform_update(self, trigger_id: str) -> str:
        if not UPDATE_LOCK.acquire(blocking=False):
            logger.info("NOPS UPDATE ALREADY RUNNING. SKIPPING TRIGGER: %s", trigger_id)
            return "SKIPPED: update already in progress"

        logger.info("NOPS UPDATE SEQUENCE INITIATED: %s", trigger_id)
        repo_dir = self.runtime_config.repo_dir
        is_controller = self.runtime_config.is_controller
        controller_script = self.runtime_config.controller_script

        try:
            self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH")
            changed_files = self._get_changed_files(repo_dir)
            needs_rebuild = self._should_rebuild(changed_files)

            if is_controller and controller_script:
                logger.info("NODE IS CONTROLLER. SYNCING REPO BEFORE CONTROLLER SCRIPT...")
                self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET-PRE")

                logger.info("EXECUTING CONTROLLER SCRIPT...")
                script_path = self._write_controller_script(controller_script)

                try:
                    self._run_command(["bash", "-c", script_path], cwd=repo_dir, stage="CONTROLLER-HOOK")
                except subprocess.CalledProcessError as error:
                    logger.warning("CONTROLLER-HOOK FAILED (non-fatal, continuing with rebuild): %s", error)

                self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH-POST")
                needs_rebuild = True
            elif not is_controller:
                logger.info("NODE IS WORKER. PAUSING 30s FOR CONTROLLER TO PROVISION SECRETS...")
                time.sleep(30)
                self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH-POST")
                changed_files = self._get_changed_files(repo_dir)
                needs_rebuild = self._should_rebuild(changed_files)

            if not needs_rebuild:
                self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET")
                logger.info("NO RELEVANT CHANGES FOUND. RESETTING REPO.")
                return "SKIPPED"

            self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET")

            output_log: list[str] = []
            for command in self.runtime_config.update_commands:
                sanitized_cmd = command.replace("\r", "")
                output_log.append(
                    self._run_command(["bash", "-c", sanitized_cmd], cwd=repo_dir, stage="REBUILD")
                )

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
            self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="BOOT")
            self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="BOOT")
        except Exception as error:
            logger.error("BOOT SYNC FAILED: %s", error)
