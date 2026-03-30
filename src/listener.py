import os
import asyncio
import logging
import socket
from typing import Optional
from nio import AsyncClient, RoomMessageText, RoomMessageNotice, SyncResponse, SyncError
from update import UpdateManager

CONFIG_PATH = os.environ.get("NOPS_CONFIG_PATH")
LOG_FILE = os.environ.get("NOPS_LOG_PATH", "/home/nops/log/main.log")

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(name)s] [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("nops-listener")

# Async Matrix bot that monitors a room and triggers nixos-rebuild on "push", "commit", or "update" messages.
class NopsListener:
    __slots__ = ('updater', 'client', 'hostname', 'next_batch')

    # Reads MATRIX_HOMESERVER, MATRIX_BOT_TOKEN, and MATRIX_ROOM_ID from the environment.
    def __init__(self):
        self.updater = UpdateManager(CONFIG_PATH)
        
        raw_url = os.environ.get("MATRIX_HOMESERVER", "").strip().rstrip("/")
        if raw_url and not raw_url.startswith("http"):
            raw_url = f"https://{raw_url}"
            
        self.client = AsyncClient(raw_url)
        self.client.access_token = os.environ.get("MATRIX_BOT_TOKEN", "").strip()
        self.hostname = socket.gethostname()
        self.next_batch: Optional[str] = None

    # Drops events from any room other than MATRIX_ROOM_ID; dispatches UpdateManager on "push", "commit", or "update".
    async def handle_message(self, room_id: str, event) -> None:
        room_id_secret = os.environ.get("MATRIX_ROOM_ID", "").strip().strip("'").strip('"')
        
        if room_id != room_id_secret:
            return

        try:
            body = getattr(event, 'body', '')
            sender = getattr(event, 'sender', 'Unknown')
            
            if any(kw in body.lower() for kw in ["push", "commit", "update"]):
                logger.info(f"UPDATE TRIGGER DETECTED FROM {sender}")
                loop = asyncio.get_event_loop()
                await loop.run_in_executor(None, self.updater.perform_update, event.event_id)
        except Exception as e:
            logger.error(f"FAILED TO PROCESS MESSAGE: {e}", exc_info=True)

    # Runs the boot sequence, performs an initial Matrix sync, then polls continuously; sleeps 10s on sync errors.
    async def main(self) -> None:
        logger.info(f"STARTING NOPS-LISTENER ON {self.client.homeserver}")
        
        try:
            self.updater.run_boot_sequence()
        except Exception as e:
            logger.error(f"STARTUP SYNC FAILED: {e}")

        try:
            logger.info("PERFORMING INITIAL SYNC...")
            initial_sync = await self.client.sync(timeout=30000)
            if not isinstance(initial_sync, SyncError):
                self.next_batch = initial_sync.next_batch
            logger.info("INITIAL SYNC COMPLETE. LISTENING FOR TRIGGERS.")
        except Exception as e:
            logger.error(f"INITIAL SYNC ERROR: {e}")

        while True:
            try:
                sync_response = await self.client.sync(timeout=30000, since=self.next_batch)
                
                if isinstance(sync_response, SyncError):
                    logger.error(f"MATRIX SYNC ERROR: {sync_response.message}")
                    await asyncio.sleep(10)
                    continue

                if hasattr(sync_response, 'next_batch'):
                    self.next_batch = sync_response.next_batch

                if isinstance(sync_response, SyncResponse) and sync_response.rooms.join:
                    for room_id, room_info in sync_response.rooms.join.items():
                        for event in room_info.timeline.events:
                            if isinstance(event, (RoomMessageText, RoomMessageNotice)):
                                await self.handle_message(room_id, event)
                                
            except Exception as e:
                logger.critical(f"DAEMON CRITICAL ERROR: {e}")
                await asyncio.sleep(5)

if __name__ == "__main__":
    listener = NopsListener()
    try:
        asyncio.run(listener.main())
    except KeyboardInterrupt:
        logger.info("DAEMON STOPPING.")
    except Exception as e:
        logger.critical(f"DAEMON CRASHED: {e}")