from __future__ import annotations

import asyncio
import os
import socket
from typing import Optional

from nio import AsyncClient, RoomMessageNotice, RoomMessageText, SyncError, SyncResponse

from .core import configure_logging
from .update import UpdateManager


class MatrixListener:
    __slots__ = ("updater", "client", "hostname", "next_batch", "logger", "room_id", "trigger_keywords")

    def __init__(self, config_path: str, log_file: str):
        self.logger = configure_logging("nops-listener", log_file=log_file)
        self.updater = UpdateManager(config_path)

        raw_url = os.environ.get("MATRIX_HOMESERVER", "").strip().rstrip("/")
        if raw_url and not raw_url.startswith("http"):
            raw_url = f"https://{raw_url}"

        self.client = AsyncClient(raw_url)
        self.client.access_token = os.environ.get("MATRIX_BOT_TOKEN", "").strip()
        self.hostname = socket.gethostname()
        self.next_batch: Optional[str] = None
        self.room_id = os.environ.get("MATRIX_ROOM_ID", "").strip().strip("'").strip('"')
        self.trigger_keywords = self.updater.runtime_config.matrix.trigger_keywords

    def should_trigger_update(self, body: str) -> bool:
        normalized = body.lower()
        return any(keyword in normalized for keyword in self.trigger_keywords)

    async def handle_message(self, room_id: str, event: object) -> None:
        if room_id != self.room_id:
            return
        try:
            body = getattr(event, "body", "")
            sender = getattr(event, "sender", "Unknown")
            if self.should_trigger_update(body):
                self.logger.info("UPDATE TRIGGER DETECTED FROM %s", sender)
                loop = asyncio.get_event_loop()
                await loop.run_in_executor(None, self.updater.perform_update, event.event_id)
        except Exception as error:
            self.logger.error("FAILED TO PROCESS MESSAGE: %s", error, exc_info=True)

    async def run(self) -> None:
        self.logger.info("STARTING NOPS-LISTENER ON %s", self.client.homeserver)
        try:
            self.updater.run_boot_sequence()
        except Exception as error:
            self.logger.error("STARTUP SYNC FAILED: %s", error)

        try:
            self.logger.info("PERFORMING INITIAL SYNC...")
            initial_sync = await self.client.sync(timeout=30000)
            if not isinstance(initial_sync, SyncError):
                self.next_batch = initial_sync.next_batch
            self.logger.info("INITIAL SYNC COMPLETE. LISTENING FOR TRIGGERS.")
        except Exception as error:
            self.logger.error("INITIAL SYNC ERROR: %s", error)

        while True:
            try:
                sync_response = await self.client.sync(timeout=30000, since=self.next_batch)
                if isinstance(sync_response, SyncError):
                    self.logger.error("MATRIX SYNC ERROR: %s", sync_response.message)
                    await asyncio.sleep(10)
                    continue

                if hasattr(sync_response, "next_batch"):
                    self.next_batch = sync_response.next_batch

                if isinstance(sync_response, SyncResponse) and sync_response.rooms.join:
                    for room_id, room_info in sync_response.rooms.join.items():
                        for event in room_info.timeline.events:
                            if isinstance(event, (RoomMessageText, RoomMessageNotice)):
                                await self.handle_message(room_id, event)
            except Exception as error:
                self.logger.critical("DAEMON CRITICAL ERROR: %s", error)
                await asyncio.sleep(5)


def main() -> None:
    config_path = os.environ.get("NOPS_CONFIG_PATH", "")
    log_file = os.environ.get("NOPS_LOG_PATH", "/home/nix-cluster/log/main.log")
    listener = MatrixListener(config_path, log_file)
    try:
        asyncio.run(listener.run())
    except KeyboardInterrupt:
        listener.logger.info("DAEMON STOPPING.")
    except Exception as error:
        listener.logger.critical("DAEMON CRASHED: %s", error)
