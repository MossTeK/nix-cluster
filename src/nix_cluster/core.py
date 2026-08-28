from __future__ import annotations

import json
import logging
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Sequence


# Write a text file by replacing it in one move, so readers never see half a file.
def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=path.parent, encoding="utf-8") as handle:
        handle.write(content)
        temp_path = Path(handle.name)
    temp_path.replace(path)


# Write a small JSON state file in the same safe way as `atomic_write_text`.
def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    atomic_write_text(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")


# Build the logger style used by the daemons: stdout first, optional file second.
def configure_logging(name: str, log_file: str | None = None, level: int = logging.INFO) -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(level)
    logger.handlers.clear()

    formatter = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    if log_file:
        path = Path(log_file)
        path.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(path)
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)

    logger.propagate = False
    return logger


# Small wrapper around subprocess so command logging and error handling stay consistent.
class ProcessRunner:
    def __init__(self, logger: logging.Logger):
        # Keep the logger that will receive command, stdout, stderr, and failure details.
        self.logger = logger

    def run(
        self,
        command: Sequence[str],
        *,
        cwd: str | None = None,
        check: bool = True,
        capture_output: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        # Run one external command and optionally raise if it exits non-zero.
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
