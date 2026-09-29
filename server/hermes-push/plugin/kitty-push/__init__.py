"""Hermes plugin wrapper around hermes_push.py: the same relay loop, run inside Hermes as a
daemon thread so nothing needs systemd or launchd. Config comes from
<HERMES_HOME>/push/hermes-push.conf (written by the Kitty app)."""
from __future__ import annotations

import logging
import sys
import threading
from pathlib import Path

log = logging.getLogger("kitty-push")
_stop = threading.Event()


def _run() -> None:
    here = Path(__file__).resolve().parent
    if str(here) not in sys.path:
        sys.path.insert(0, str(here))
    try:
        import asyncio
        import importlib
        import hermes_push
        hermes_push._load_conf()
        if not _claim_single_instance(hermes_push):
            return
        while not _stop.is_set():
            try:
                asyncio.run(hermes_push.Relay().run())
                return
            except hermes_push.CodeChanged:
                # The app put a newer hermes_push.py next to us: pick it up in place, no gateway restart.
                log.info("kitty-push: reloading updated hermes_push.py")
                hermes_push = importlib.reload(hermes_push)
                hermes_push._CONF.clear()
                hermes_push._load_conf()
    except SystemExit as exc:
        log.warning("kitty-push not started: %s", exc)
    except Exception:  # noqa: BLE001
        log.exception("kitty-push relay stopped")


_lock_handle = None


def _claim_single_instance(hermes_push) -> bool:
    """Hermes loads plugins in more than one process (dashboard, gateway). Only one relay may run,
    or every push arrives twice. Others wait for the lock rather than giving up: during a gateway
    restart the old process can still hold it for a few seconds after the new one has started."""
    global _lock_handle
    try:
        import fcntl
        import time
    except ImportError:  # Windows: no advisory locks, run regardless
        return True
    path = hermes_push.status_path().with_name("relay.lock")
    path.parent.mkdir(parents=True, exist_ok=True)
    _lock_handle = open(path, "w")
    waited = False
    while not _stop.is_set():
        try:
            fcntl.flock(_lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if waited:
                log.info("kitty-push relay lock acquired; starting")
            return True
        except OSError:
            if not waited:
                log.info("kitty-push relay running in another Hermes process; waiting for it to stop")
                waited = True
            time.sleep(5)
    return False


def register(ctx) -> None:
    t = threading.Thread(target=_run, name="kitty-push", daemon=True)
    t.start()
    try:
        ctx.on_unload(lambda: _stop.set())
    except Exception:  # noqa: BLE001
        pass
    log.info("kitty-push plugin started")
