import os
import asyncio
import contextlib
import logging
import ssl
from aiohttp import web
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
logger = logging.getLogger("nops-webhook")

updater = UpdateManager(CONFIG_PATH)

async def periodic_reconcile(app):
    interval = updater.config.get("controller", {}).get("reconcile_interval_seconds", 0)
    is_controller = updater.config.get("is_controller", False)

    if not is_controller or interval <= 0:
        logger.info("PERIODIC CONTROLLER RECONCILIATION DISABLED")
        return

    logger.info(f"STARTING PERIODIC CONTROLLER RECONCILIATION EVERY {interval}s")

    while True:
        await asyncio.sleep(interval)
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, updater.perform_update, "periodic-reconcile")


async def periodic_reconcile_ctx(app):
    task = asyncio.create_task(periodic_reconcile(app))
    try:
        yield
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

# Accepts POST from Forgejo/GitLab/GitHub. Uses after commit hash as trigger ID; skips if "[skip nops]" is in the first commit message.
async def handle_webhook(request):
    logger.info("WEBHOOK PUSH EVENT DETECTED")

    try:
        payload = await request.json()
        trigger_id = payload.get("after", "webhook-push")

        if 'commits' in payload and payload['commits']:
            commit_msg = payload['commits'][0].get('message', '')
            if '[skip nops]' in commit_msg:
                logger.info("DETECTED '[skip nops]' IN COMMIT. IGNORING WEBHOOK.")
                return web.Response(text="Ignored due to skip flag.\n", status=200)
                
    except Exception:
        trigger_id = "webhook-push"
        
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, updater.perform_update, trigger_id)
    
    return web.Response(text="Nops Update Triggered successfully.\n")

# Runs the boot sync and registers POST handlers at / and /webhook.
async def init_app():
    logger.info("INITIALIZING NOPS-WEBHOOK...")
    try:
        updater.run_boot_sequence()
    except Exception as e:
        logger.error(f"STARTUP SYNC FAILED: {e}")

    app = web.Application()
    app.cleanup_ctx.append(periodic_reconcile_ctx)
    app.router.add_post('/webhook', handle_webhook)
    app.router.add_post('/', handle_webhook)
    return app

if __name__ == '__main__':
    port = int(os.environ.get("WEBHOOK_PORT", "8080"))
    cert_file = os.environ.get("WEBHOOK_SSL_CERT", "")
    key_file = os.environ.get("WEBHOOK_SSL_KEY", "")

    ssl_context = None
    if cert_file and key_file:
        logger.info(f"CONFIGURING SSL WITH CERT: {cert_file}")
        ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(certfile=cert_file, keyfile=key_file)
        logger.info(f"STARTING NOPS-WEBHOOK ON PORT {port} WITH SSL")
    else:
        logger.info(f"STARTING NOPS-WEBHOOK ON PORT {port} (HTTP ONLY)")

    web.run_app(init_app(), host='0.0.0.0', port=port, ssl_context=ssl_context)