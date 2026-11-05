"""Durable connector journal, protocol errors, and Slack message primitives."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile


class Unavailable(Exception):
    """Safe, content-free error for local status reporting."""


class Denied(Unavailable):
    """An authoritative authorization refusal, distinct from transport loss."""


class StaleAttachment(Unavailable):
    """Authoritative snapshot refused an obsolete attachment binding."""


class StaleBrowser(Unavailable):
    """The session-to-thread binding is no longer authoritative."""


class StaleNativeState(Unavailable):
    """The native turn or pending requests changed before delivery."""


class StaleAway(Unavailable):
    """Away is off, its scope changed, or the event is obsolete."""


class RateLimited(Unavailable):
    def __init__(self, retry_after):
        self.retry_after = max(0.01, float(retry_after))


class Journal:
    MAX_BYTES = 16 * 1024 * 1024

    def __init__(self, path):
        self.path = Path(path)
        self.failed = False
        if self.path.exists():
            if self.path.stat().st_size > self.MAX_BYTES:
                raise Unavailable("Connector journal too large")
            self.data = json.loads(self.path.read_text())
            if self.data.get("version") != 1:
                raise Unavailable("Unsupported connector journal")
        else:
            self.data = {"version": 1, "incoming": {}, "posts": {}, "controls": {}, "modals": {}, "cursors": {}}
        # Older native-only journals have no session-browser mappings.
        self.data.setdefault("browserThreads", {})
        self.data.setdefault("awaySeen", {})
        # A process crash does not prove that an HTTP or Slack submission failed.
        for group in ("incoming", "posts"):
            for value in self.data[group].values():
                if value.get("status") == "sending":
                    value["status"] = "uncertain"

    def commit(self, mutation):
        if self.failed:
            raise Unavailable("Connector storage unavailable")
        next_data = copy.deepcopy(self.data)
        mutation(next_data)
        encoded = json.dumps(next_data, separators=(",", ":")).encode()
        if len(encoded) > self.MAX_BYTES:
            raise Unavailable("Connector journal full; preserve deduplication evidence")
        temporary = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor, temporary = tempfile.mkstemp(dir=self.path.parent)
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb") as output:
                output.write(encoded)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
            self.data = next_data
        except OSError:
            self.failed = True
            raise Unavailable("Connector journal write failed") from None
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)


def stable_id(*parts):
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()


def plain(text):
    return {"type": "plain_text", "text": str(text)[:2900] or " "}


def section(text):
    return {"type": "section", "text": plain(text)}
