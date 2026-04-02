from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any, Dict, List

DEFAULT_CONFIG_PATH = "/etc/nops-runtime-config.json"


@dataclass(slots=True)
class RuntimeConfig:
    path: str
    raw: Dict[str, Any]

    @classmethod
    def from_path(cls, path: str | None = None) -> "RuntimeConfig":
        resolved = path or os.environ.get("NOPS_CONFIG_PATH", DEFAULT_CONFIG_PATH)
        with open(resolved, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
        return cls(path=resolved, raw=raw)

    @property
    def repo_dir(self) -> str:
        return self.raw["directories"]["repo"]

    @property
    def is_controller(self) -> bool:
        return bool(self.raw.get("is_controller", False))

    @property
    def controller_script(self) -> str:
        return self.raw.get("controller_script", "")

    @property
    def update_commands(self) -> List[str]:
        commands = self.raw.get("commands", {}).get("update", [])
        if isinstance(commands, list):
            return [str(command) for command in commands]
        return [str(commands)]

    @property
    def hostname(self) -> str:
        return self.raw.get("hostname", "")

    @property
    def controller_reconcile_interval_seconds(self) -> int:
        return int(self.raw.get("controller", {}).get("reconcile_interval_seconds", 0))

    @property
    def observability(self) -> Dict[str, Any]:
        return self.raw.get("observability", {})

    @property
    def ha(self) -> Dict[str, Any]:
        return self.raw.get("ha", {})

    @property
    def directories(self) -> Dict[str, Any]:
        return self.raw.get("directories", {})
