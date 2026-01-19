import os
import hmac
import hashlib
import logging
from typing import Optional
from flask import Flask, request, jsonify
from waitress import serve
from update import UpdateManager

# config setup
OPS_CONFIG_PATH = os.environ.get("NAD_CONFIG_PATH", 
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "ops.yaml"))

LOG_FILE = os.environ.get("NAD_LOG_PATH", "/home/nad/nad/log/main.log")

# logging logic
try:
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    file_handler = logging.FileHandler(LOG_FILE)
except OSError:
    file_handler = logging.NullHandler()

logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(levelname)s - %(process)d - %(message)s',
    handlers=[file_handler, logging.StreamHandler()]
)
logger = logging.getLogger("NAD-Webhook")

app = Flask(__name__)
WEBHOOK_SECRET = os.environ.get("FORGEJO_WEBHOOK_SECRET")

# init update manager
updater = UpdateManager(OPS_CONFIG_PATH)

# security helper
class SecurityValidator:
    def __init__(self, secret: Optional[str]):
        self._secret = secret

    def validate_signature(self, payload: bytes, header_signature: str) -> bool:
        if not self._secret or not header_signature:
            return False
        try:
            mac = hmac.new(self._secret.encode('utf-8'), msg=payload, digestmod=hashlib.sha256)
            return hmac.compare_digest(mac.hexdigest(), header_signature)
        except Exception:
            return False

validator = SecurityValidator(WEBHOOK_SECRET)

# webhook route
@app.route('/webhook', methods=['POST'])
def webhook_endpoint():
    sig = (request.headers.get('X-Forgejo-Signature') or request.headers.get('X-Hub-Signature-256'))
    if sig and sig.startswith('sha256='): sig = sig.split('=', 1)[1]
    
    # auth check
    if not validator.validate_signature(request.get_data(), sig):
        logger.warning("SECURITY ALERT: Invalid signature.")
        return jsonify({"error": "Unauthorized"}), 403

    # process update
    try:
        payload = request.get_json()
        commit_id = payload.get('after', 'manual_trigger')
        logger.info(f"Triggering update for commit: {commit_id}")
        logs = updater.perform_update(commit_id)
        return jsonify({"status": "success", "logs": logs}), 200
    except Exception as e:
        logger.exception("Update pipeline failed")
        return jsonify({"error": str(e)}), 500

# start server
if __name__ == '__main__':
    try:
        updater.run_boot_sequence()
    except Exception as e:
        logger.error(f"Boot failed: {e}")
    
    # prod server
    serve(app, host='0.0.0.0', port=5000)