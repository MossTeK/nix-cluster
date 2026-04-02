from __future__ import annotations

import asyncio
import contextlib
import os
import ssl

from aiohttp import web

from .core import configure_logging
from .update import UpdateManager


class WebhookServer:
    def __init__(self, config_path: str, log_file: str):
        self.logger = configure_logging("nix-cluster-webhook", log_file=log_file)
        self.updater = UpdateManager(config_path)
        self.config = self.updater.runtime_config

    async def periodic_reconcile(self) -> None:
        interval = self.config.controller.reconcile_interval_seconds
        if not self.config.is_controller or interval <= 0:
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
                skip_markers = [self.config.webhook.skip_commit_marker, "[skip nix-cluster]", "[skip nops]"]
                matched_marker = next((marker for marker in skip_markers if marker and marker in commit_msg), None)
                if matched_marker is not None:
                    self.logger.info("DETECTED '%s' IN COMMIT. IGNORING WEBHOOK.", matched_marker)
                    return web.Response(text="Ignored due to skip flag.\n", status=200)
        except Exception:
            trigger_id = "webhook-push"

        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, self.updater.perform_update, trigger_id)
        return web.Response(text="nix-cluster update triggered successfully.\n")

    async def init_app(self) -> web.Application:
        self.logger.info("INITIALIZING NIX-CLUSTER-WEBHOOK...")
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
    config_path = (
        os.environ.get("NIX_CLUSTER_CONFIG_PATH")
        or os.environ.get("NOPS_CONFIG_PATH")
        or ("/etc/nix-cluster-runtime-config.json" if os.path.exists("/etc/nix-cluster-runtime-config.json") else "/etc/nops-runtime-config.json")
    )
    log_file = os.environ.get("NIX_CLUSTER_LOG_PATH", os.environ.get("NOPS_LOG_PATH", "/home/nix-cluster/log/main.log"))
    server = WebhookServer(config_path, log_file)

    ssl_context = None
    if server.config.webhook.ssl_cert and server.config.webhook.ssl_key:
        server.logger.info("CONFIGURING SSL WITH CERT: %s", server.config.webhook.ssl_cert)
        ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(certfile=server.config.webhook.ssl_cert, keyfile=server.config.webhook.ssl_key)
        server.logger.info("STARTING NIX-CLUSTER-WEBHOOK ON %s:%s WITH SSL", server.config.webhook.bind_address, server.config.webhook.port)
    else:
        server.logger.info("STARTING NIX-CLUSTER-WEBHOOK ON %s:%s (HTTP ONLY)", server.config.webhook.bind_address, server.config.webhook.port)

    web.run_app(
        server.init_app(),
        host=server.config.webhook.bind_address,
        port=server.config.webhook.port,
        ssl_context=ssl_context,
    )


if __name__ == "__main__":
    main()
