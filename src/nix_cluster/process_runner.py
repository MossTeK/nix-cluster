from __future__ import annotations

import logging
import subprocess
from pathlib import Path
from typing import Sequence


class ProcessRunner:
    def __init__(self, logger: logging.Logger):
        self.logger = logger

    def run(
        self,
        command: Sequence[str],
        *,
        cwd: str | None = None,
        check: bool = True,
        capture_output: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        self.logger.info("Running command: %s", " ".join(command))
        result = subprocess.run(
            list(command),
            cwd=cwd,
            check=False,
            text=True,
            capture_output=capture_output,
        )

        if result.stdout:
            self.logger.info(result.stdout.strip())
        if result.stderr:
            self.logger.warning(result.stderr.strip())

        if check and result.returncode != 0:
            raise subprocess.CalledProcessError(
                result.returncode,
                list(command),
                output=result.stdout,
                stderr=result.stderr,
            )

        return result

    def run_shell(self, command: str, *, cwd: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
        self.logger.info("Running shell command: %s", command)
        result = subprocess.run(
            command,
            cwd=cwd,
            check=False,
            text=True,
            capture_output=True,
            shell=True,
        )

        if result.stdout:
            self.logger.info(result.stdout.strip())
        if result.stderr:
            self.logger.warning(result.stderr.strip())

        if check and result.returncode != 0:
            raise subprocess.CalledProcessError(
                result.returncode,
                command,
                output=result.stdout,
                stderr=result.stderr,
            )

        return result

    @staticmethod
    def read_text(path: str) -> str:
        return Path(path).read_text(encoding="utf-8")
