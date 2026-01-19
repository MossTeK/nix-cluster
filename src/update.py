import os
import subprocess
import logging
import yaml
from typing import List, Dict, Any

logger = logging.getLogger(__name__)

class UpdateManager:
    #init setup
    def __init__(self, config_path: str):
        self.config_path = config_path
        self.config = self._load_config()

    #load config
    def _load_config(self) -> Dict[str, Any]:
        try:
            with open(self.config_path, 'r') as f:
                return yaml.safe_load(f)
        except Exception as e:
            logger.error(f"Failed to load config: {e}")
            raise

    #shell helper
    def _run_command(self, cmd: List[str], cwd: str) -> str:
        logger.info(f"Running: {' '.join(cmd)}")
        result = subprocess.run(
            cmd, cwd=cwd, check=True, capture_output=True, text=True
        )
        return result.stdout

    #main update logic
    def perform_update(self, commit_id: str) -> str:
        logger.info(f"Updating to commit: {commit_id}")
        repo_dir = self.config['directories']['repo']
        logs = []

        #git sync
        try:
            self._run_command(["git", "fetch", "origin", "main"], cwd=repo_dir)
            out = self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir)
            logs.append(f"GIT SYNC:\n{out}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Git sync failed: {e.stderr}")
            return f"GIT ERROR: {e.stderr}"

        #run rebuild
        rebuild_cmds = self.config['commands'].get('rebuild', [])
        for cmd in rebuild_cmds:
            try:
                out = self._run_command(cmd, cwd=repo_dir)
                logs.append(f"REBUILD:\n{out}")
            except subprocess.CalledProcessError as e:
                logger.error(f"Rebuild failed: {e.stderr}")
                return f"\n".join(logs) + f"\nCRITICAL FAILURE:\n{e.stderr}"

        return "\n".join(logs)

    #boot sequence
    def run_boot_sequence(self):
        repo_dir = self.config['directories']['repo']
        for cmd in self.config['commands'].get('boot', []):
            try:
                self._run_command(cmd, cwd=repo_dir)
            except Exception as e:
                logger.error(f"Boot command failed: {e}")