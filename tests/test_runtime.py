import io
import unittest
import urllib.error
from unittest.mock import patch

from nix_cluster.runtime import EtcdClient, RuntimeStoreWriteBlocked


class RuntimeStoreTests(unittest.TestCase):
    def test_keepalive_returns_server_ttl(self):
        client = EtcdClient("http://127.0.0.1:2379")
        client._request_json = lambda path, payload, timeout: {"result": {"TTL": 77}}
        self.assertEqual(client.keep_alive_lease(123), 77)

    def test_etcd_nospace_429_is_write_blocked(self):
        error = urllib.error.HTTPError(
            url="http://127.0.0.1:2379/v3/kv/put",
            code=429,
            msg="Too Many Requests",
            hdrs={},
            fp=io.BytesIO(b'{"error":"etcdserver: mvcc: database space exceeded"}'),
        )

        with patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(RuntimeStoreWriteBlocked) as raised:
                EtcdClient("http://127.0.0.1:2379").put_json("/demo", {"ok": True})

        self.assertEqual(raised.exception.endpoint, "http://127.0.0.1:2379")

    def test_delete_keys_uses_single_transaction(self):
        client = EtcdClient("http://127.0.0.1:2379")
        calls = []
        client._request_json = lambda path, payload, timeout: calls.append((path, payload, timeout)) or {}

        client.delete_keys(["/a", "/b"])

        self.assertEqual(calls[0][0], "/v3/kv/txn")
        deletes = calls[0][1]["success"]
        self.assertEqual(len(deletes), 2)
        self.assertIn("request_delete_range", deletes[0])


if __name__ == "__main__":
    unittest.main()
