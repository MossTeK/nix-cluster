import os
import subprocess
import logging
import json
import threading
from typing import List, Dict, Any

logger = logging.getLogger("nops-update")

UPDATE_LOCK = threading.Lock()

# Executes git fetch/reset and nixos-rebuild commands derived from the JSON config produced by the nops NixOS module.
class UpdateManager:
    __slots__ = ('config_path', 'config', 'hostname')

    # Loads config from the Nix-generated JSON file at config_path.
    def __init__(self, config_path: str):
        self.config_path = config_path
        self.config = self._load_config()
        self.hostname = subprocess.getoutput("hostname")

    # Reads and parses the Nix-generated JSON config file; raises on failure.
    def _load_config(self) -> Dict[str, Any]:
        try:
            with open(self.config_path, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"FAILED TO LOAD NOPS CONFIG: {e}")
            raise

    # Runs a subprocess, streams stdout/stderr to the logger under the given stage label, and raises CalledProcessError on non-zero exit.
    def _run_command(self, cmd: List[str], cwd: str, stage: str) -> str:
        command_str = " ".join(cmd)
        logger.info(f"{stage} START: {command_str}")

        result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)

        if result.stdout:
            for line in result.stdout.splitlines():
                logger.info(f"{stage} OUTPUT: {line}")

        if result.stderr:
            log_func = logger.error if result.returncode != 0 else logger.info
            for line in result.stderr.splitlines():
                log_func(f"{stage} MESSAGE: {line}")

        if result.returncode != 0:
            logger.error(f"{stage} FAILED WITH CODE {result.returncode}")
            raise subprocess.CalledProcessError(result.returncode, cmd, output=result.stdout, stderr=result.stderr)

        logger.info(f"{stage} SUCCESS: {command_str}")
        return result.stdout.strip()

    # Returns files differing between local HEAD and origin/main; returns an empty list on error.
    def _get_changed_files(self, repo_dir: str) -> List[str]:
        try:
            output = self._run_command(["git", "diff", "--name-only", "HEAD", "origin/main"], cwd=repo_dir, stage="GIT-DIFF")
            return output.splitlines()
        except Exception:
            return []

    # Returns True if any changed path falls under this node's directory, shared groups/, modules/, deployments.json, secrets/, or flake files.
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
            "flake.lock"
        ]
        
        for f in changed_files:
            if any(f.startswith(path) for path in relevant_paths):
                logger.info(f"RELEVANT CHANGE DETECTED: {f}")
                return True
        
        return False

    # Executes the update pipeline.
    # Fetches the remote repository to evaluate changes before running controller logic to avoid masking triggering commits.
    # Forces a rebuild if the node acts as a controller, otherwise evaluates changes for worker nodes.
    def perform_update(self, trigger_id: str) -> str:
        if not UPDATE_LOCK.acquire(blocking=False):
            logger.info(f"NOPS UPDATE ALREADY RUNNING. SKIPPING TRIGGER: {trigger_id}")
            return "SKIPPED: update already in progress"

        logger.info(f"NOPS UPDATE SEQUENCE INITIATED: {trigger_id}")
        repo_dir = self.config['directories']['repo']
        is_controller = self.config.get('is_controller', False)
        controller_script = self.config.get('controller_script', "")

        try:
            self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH")
            changed_files = self._get_changed_files(repo_dir)
            needs_rebuild = self._should_rebuild(changed_files)

            if is_controller and controller_script:
                logger.info("NODE IS CONTROLLER. SYNCING REPO BEFORE CONTROLLER SCRIPT...")
                self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET-PRE")

                logger.info("EXECUTING CONTROLLER SCRIPT...")
                script_path = "/tmp/nops_controller.sh"
                # FORCE LF: Write with newline='\n' and strip any existing \r characters
                with open(script_path, "w", newline='\n') as f:
                    f.write(controller_script.replace('\r', ''))
                os.chmod(script_path, 0o755)
                
                try:
                    self._run_command(["bash", "-c", script_path], cwd=repo_dir, stage="CONTROLLER-HOOK")
                except subprocess.CalledProcessError as e:
                    logger.warning(f"CONTROLLER-HOOK FAILED (non-fatal, continuing with rebuild): {e}")

                self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH-POST")
                needs_rebuild = True

            elif not is_controller:
                logger.info("NODE IS WORKER. PAUSING 30s FOR CONTROLLER TO PROVISION SECRETS...")
                import time
                time.sleep(30)
                
                self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH-POST")
                changed_files = self._get_changed_files(repo_dir)
                needs_rebuild = self._should_rebuild(changed_files)

            if not needs_rebuild:
                self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET")
                logger.info("NO RELEVANT CHANGES FOUND. RESETTING REPO.")
                return "SKIPPED"

            self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET")
            
            rebuild_cmds = self.config['commands']['update']
            output_log = ""
            
            # SANITIZATION: Ensure all rebuild commands are stripped of carriage returns
            if isinstance(rebuild_cmds, list):
                for cmd in rebuild_cmds:
                    sanitized_cmd = cmd.replace('\r', '')
                    output_log += self._run_command(["bash", "-c", sanitized_cmd], cwd=repo_dir, stage="REBUILD") + "\n"
            else:
                sanitized_cmd = rebuild_cmds.replace('\r', '')
                output_log = self._run_command(["bash", "-c", sanitized_cmd], cwd=repo_dir, stage="REBUILD")
            
            logger.info(f"NOPS REBUILD TASK COMPLETED: {trigger_id}")
            return output_log.strip()

        except Exception as e:
            logger.error(f"NOPS UPDATE PIPELINE FAILED: {str(e)}")
            return f"FAILURE: {str(e)}"
        finally:
            UPDATE_LOCK.release()

    # Fetches origin and hard-resets to origin/main so the daemon starts with current fleet state.
    def run_boot_sequence(self):
        repo_dir = self.config['directories']['repo']
        logger.info("INITIALIZING BOOT SYNCHRONIZATION...")
        try:
            self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="BOOT")
            self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="BOOT")
        except Exception as e:
            logger.error(f"BOOT SYNC FAILED: {e}")