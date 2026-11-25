import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HELPER = os.environ.get("BINGHELPER") or str(Path(__file__).resolve().parent.parent / "binghelper" / "binghelper")
IMAGE_BYTES = b"\xff\xd8\xff\xe0binghelper-test-image\xff\xd9"


class Handler(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_args):
        pass

    def do_GET(self):
        type(self).requests.append(self.path)
        if self.path.startswith("/HPImageArchive.aspx"):
            query = dict(part.split("=", 1) for part in self.path.split("?", 1)[1].split("&"))
            market = query["mkt"]
            idx = int(query["idx"])
            if idx == 0:
                images = [
                    {
                        "startdate": "20261120",
                        "enddate": "20261121",
                        "urlbase": "/th?id=OHR.Palmanova_" + market.upper() + "034",
                        "title": "Palmanova",
                        "copyright": "Test (c) " + market,
                    },
                    {
                        "startdate": "20261119",
                        "enddate": "20261120",
                        "urlbase": "/th?id=OHR.Shared_" + market.upper() + "035",
                        "title": "Shared",
                        "copyright": "Test (c) " + market,
                    },
                ]
            else:
                images = []
            body = json.dumps({"images": images}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        name = self.path.split("OHR.", 1)[1].split("_")[0] if "OHR." in self.path else "none"
        body = IMAGE_BYTES + name.encode()
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class HelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Handler.requests.clear()
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.env = dict(os.environ)
        self.env.update(
            {
                "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_DATA_HOME": str(root / "data"),
                "XDG_RUNTIME_DIR": str(root),
                "SINGULARITY_BINGHELPER_DATA": str(root / "archive"),
                "SINGULARITY_BINGHELPER_THUMBS": str(root / "thumbs"),
                "SINGULARITY_BINGHELPER_ENDPOINT": f"http://127.0.0.1:{self.port}/HPImageArchive.aspx",
                "SINGULARITY_BINGHELPER_IMAGE_BASE": f"http://127.0.0.1:{self.port}",
                "SINGULARITY_BINGHELPER_PROBE_HOST": "127.0.0.1",
                "SINGULARITY_BINGHELPER_PROBE_PORT": str(self.port),
                "SINGULARITY_BINGHELPER_IGNORE_METERED": "1",
                "SINGULARITY_BINGHELPER_QUIET": "1",
            }
        )
        self.env.pop("SINGULARITY_BINGHELPER_MARKETS", None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_helper(self, *args, env=None):
        return subprocess.run(
            [sys.executable, HELPER, *args], capture_output=True, text=True, env=env or self.env, timeout=120
        )

    def test_help_exits_zero(self):
        result = self.run_helper("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("singularity-binghelper", result.stdout)

    def test_markets_lists_combined_view_first(self):
        result = self.run_helper("markets")
        self.assertEqual(result.returncode, 0)
        lines = result.stdout.splitlines()
        self.assertTrue(lines[0].startswith("consolidated\t"))
        self.assertIn("en-US\tUnited States", lines)

    def test_market_preference_round_trip(self):
        self.assertEqual(self.run_helper("market", "en-gb").returncode, 0)
        self.assertEqual(self.run_helper("market").stdout.strip(), "en-GB")
        self.assertEqual(self.run_helper("market", "all").returncode, 0)
        self.assertEqual(self.run_helper("market").stdout.strip(), "all")

    def test_unknown_market_is_rejected(self):
        self.assertEqual(self.run_helper("market", "xx-YY").returncode, 2)

    def test_fetch_archives_and_consolidates(self):
        result = self.run_helper("fetch")
        self.assertEqual(result.returncode, 0, result.stderr)
        archived = json.loads(self.run_helper("list", "--all").stdout)
        self.assertTrue(archived)
        self.assertTrue(all(entry["path"].endswith(".jpg") and Path(entry["path"]).is_file() for entry in archived))
        combined = json.loads(self.run_helper("list", "--consolidated").stdout)
        names = {entry["caption"] for entry in combined}
        self.assertEqual(names, {"Palmanova", "Shared"})
        self.assertLess(len(combined), len(archived))

    def test_if_stale_does_nothing_after_a_fresh_fetch(self):
        self.assertEqual(self.run_helper("fetch").returncode, 0)
        Handler.requests.clear()
        result = self.run_helper("fetch", "--if-stale")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(Handler.requests, [])

    def test_unreachable_network_exits_75(self):
        env = dict(self.env)
        dead = free_port()
        env["SINGULARITY_BINGHELPER_ENDPOINT"] = f"http://127.0.0.1:{dead}/HPImageArchive.aspx"
        env["SINGULARITY_BINGHELPER_IMAGE_BASE"] = f"http://127.0.0.1:{dead}"
        env["SINGULARITY_BINGHELPER_PROBE_PORT"] = str(dead)
        self.assertEqual(self.run_helper("fetch", env=env).returncode, 75)

    def test_pin_and_unpin(self):
        self.assertEqual(self.run_helper("fetch").returncode, 0)
        self.assertEqual(self.run_helper("pin", "en-US", "20261120").returncode, 0)
        marker = Path(self.env["SINGULARITY_BINGHELPER_DATA"]) / "en-US" / "20261120.pinned"
        self.assertTrue(marker.is_file())
        self.assertEqual(self.run_helper("unpin", "en-US", "20261120").returncode, 0)
        self.assertFalse(marker.exists())

    def test_pin_validates_arguments(self):
        self.assertEqual(self.run_helper("pin", "en-US").returncode, 2)
        self.assertEqual(self.run_helper("pin", "en-US", "20261120").returncode, 1)


if __name__ == "__main__":
    unittest.main()
