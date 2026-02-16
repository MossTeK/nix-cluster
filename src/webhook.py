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

    def validate_request(self, req: request) -> bool:
        """
        Validates the request using either GitLab Token or HMAC Signature.
        """
        if not self._secret:
            logger.error("Security Error: No Webhook Secret configured.")
            return False

        # 1. GitLab Validation (Header: X-Gitlab-Token)
        # GitLab sends the raw secret token. We use compare_digest to prevent timing attacks.
        gitlab_token = req.headers.get('X-Gitlab-Token')
        if gitlab_token:
            return hmac.compare_digest(self._secret, gitlab_token)

        # 2. Forgejo/GitHub Validation (Header: X-Hub-Signature-256)
        # These services sign the payload with HMAC-SHA256.
        sig = req.headers.get('X-Forgejo-Signature') or req.headers.get('X-Hub-Signature-256')
        
        if sig:
            if sig.startswith('sha256='): 
                sig = sig.split('=', 1)[1]
            
            try:
                payload = req.get_data()
                mac = hmac.new(self._secret.encode('utf-8'), msg=payload, digestmod=hashlib.sha256)
                return hmac.compare_digest(mac.hexdigest(), sig)
            except Exception:
                return False

        return False

validator = SecurityValidator(WEBHOOK_SECRET)

# webhook route
@app.route('/webhook', methods=['POST'])
def webhook_endpoint():
    # auth check
    if not validator.validate_request(request):
        logger.warning(f"SECURITY ALERT: Unauthorized request from {request.remote_addr}")
        return jsonify({"error": "Unauthorized"}), 403

    # process update
    try:
        payload = request.get_json()
        # GitLab and GitHub use different keys for the commit hash
        # v1.2.6 Original: payload.get('after', 'manual_trigger')
        # Updated to support GitLab's 'checkout_sha' as well
        commit_id = payload.get('after', payload.get('checkout_sha', 'manual_trigger'))
        
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