from __future__ import annotations

import asyncio
import contextlib
import os
import ssl

from aiohttp import web

from .logging_utils import configure_logging
from .update_manager import UpdateManager


class WebhookServer:
    def __init__(self, config_path: str, log_file: str):
        self.logger = configure_logging("nops-webhook", log_file=log_file)
        self.updater = UpdateManager(config_path)

    async def periodic_reconcile(self) -> None:
        interval = self.updater.runtime_config.controller_reconcile_interval_seconds
        if not self.updater.runtime_config.is_controller or interval <= 0:
            self.logger.info("PERIODIC CONTROLLER RECONCILIATION DISABLED")
            return

        self.logger.info("STARTING PERIODIC CONTROLLER RECONCILIATION EVERY %ss", interval)
        while True:
            await asyncio.sleep(interval)
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, self.updater.perform_update, "periodic-reconcile")

    async def periodic_reconcile_ctx(self, _app: web.Application):
        task = asyncio.create_task(self.periodic_reconcile())
        try:
            yield
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    async def handle_webhook(self, request: web.Request) -> web.Response:
        self.logger.info("WEBHOOK PUSH EVENT DETECTED")
        try:
            payload = await request.json()
            trigger_id = payload.get("after", "webhook-push")
            if payload.get("commits"):
                commit_msg = payload["commits"][0].get("message", "")
                if "[skip nops]" in commit_msg:
                    self.logger.info("DETECTED '[skip nops]' IN COMMIT. IGNORING WEBHOOK.")
                    return web.Response(text="Ignored due to skip flag.\n", status=200)
        except Exception:
            trigger_id = "webhook-push"

        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, self.updater.perform_update, trigger_id)
        return web.Response(text="Nops Update Triggered successfully.\n")

    async def init_app(self) -> web.Application:
        self.logger.info("INITIALIZING NOPS-WEBHOOK...")
        try:
            self.updater.run_boot_sequence()
        except Exception as error:
            self.logger.error("STARTUP SYNC FAILED: %s", error)

        app = web.Application()
        app.cleanup_ctx.append(self.periodic_reconcile_ctx)
        app.router.add_post("/webhook", self.handle_webhook)
        app.router.add_post("/", self.handle_webhook)
        return app


def main() -> None:
    config_path = os.environ.get("NOPS_CONFIG_PATH", "")
    log_file = os.environ.get("NOPS_LOG_PATH", "/home/nix-cluster/log/main.log")
    port = int(os.environ.get("WEBHOOK_PORT", "8080"))
    cert_file = os.environ.get("WEBHOOK_SSL_CERT", "")
    key_file = os.environ.get("WEBHOOK_SSL_KEY", "")

    server = WebhookServer(config_path, log_file)

    ssl_context = None
    if cert_file and key_file:
        server.logger.info("CONFIGURING SSL WITH CERT: %s", cert_file)
        ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(certfile=cert_file, keyfile=key_file)
        server.logger.info("STARTING NOPS-WEBHOOK ON PORT %s WITH SSL", port)
    else:
        server.logger.info("STARTING NOPS-WEBHOOK ON PORT %s (HTTP ONLY)", port)

    web.run_app(server.init_app(), host="0.0.0.0", port=port, ssl_context=ssl_context)
