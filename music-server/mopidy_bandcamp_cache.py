"""Disk cache for mopidy-bandcamp HTTP responses.

Upstream mopidy-bandcamp 1.x makes one HTTPS round-trip per track lookup
with no on-disk cache, so loading a 67-track M3U playlist takes ~38s on
a Pi Zero 2 W — long enough for Iris to time out and render the playlist
as empty. This addon caches the raw API responses to disk; second loads
take milliseconds and survive restarts.

Installed by setup.sh as mopidy_bandcamp/_cache.py and loaded via a
single-line import added to mopidy_bandcamp/__init__.py.

Playback (translate_uri) bypasses the cache because Bandcamp streaming
URLs are signed and expire.
"""

import hashlib
import json
import logging
import os
import tempfile
import time
from pathlib import Path

CACHE_DIR = Path("/var/cache/mopidy/bandcamp")
TTL_SECONDS = 365 * 24 * 60 * 60

logger = logging.getLogger(__name__)


def _cache_path(key):
    h = hashlib.sha256(key.encode("utf-8")).hexdigest()
    return CACHE_DIR / h[:2] / h


def _load(key):
    p = _cache_path(key)
    try:
        st = p.stat()
    except OSError:
        return None
    if time.time() - st.st_mtime > TTL_SECONDS:
        return None
    try:
        with open(p, "r") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _store(key, value):
    p = _cache_path(key)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".tmp.")
        with os.fdopen(fd, "w") as f:
            json.dump(value, f)
        os.replace(tmp, p)
    except (OSError, TypeError) as e:
        logger.debug("bandcamp cache write failed for %s: %s", key, e)


def _install():
    from mopidy_bandcamp import bandcamp as _bc_mod
    from mopidy_bandcamp import backend as _backend_mod

    Client = _bc_mod.BandcampClient
    orig_get_album = Client.get_album
    orig_get_artist = Client.get_artist
    orig_scrape = Client.scrape

    def get_album(self, artistid, itemid, track=False):
        key = f"album|{artistid}|{itemid}|{int(bool(track))}"
        cached = _load(key)
        if cached is not None:
            return cached
        result = orig_get_album(self, artistid, itemid, track=track)
        _store(key, result)
        return result

    def get_artist(self, artistid):
        key = f"artist|{artistid}"
        cached = _load(key)
        if cached is not None:
            return cached
        result = orig_get_artist(self, artistid)
        _store(key, result)
        return result

    def scrape(self, uri):
        key = f"scrape|{uri}"
        cached = _load(key)
        if cached is not None:
            return cached
        result = orig_scrape(self, uri)
        _store(key, result)
        return result

    Client.get_album = get_album
    Client.get_artist = get_artist
    Client.scrape = scrape

    # Playback path must always see fresh streaming URLs (Bandcamp signs and
    # expires them). Shadow the cached methods with the originals on the
    # client instance for the duration of translate_uri. The backend is a
    # single-threaded Pykka actor so no lock is needed.
    Playback = _backend_mod.BandcampPlaybackProvider
    orig_translate = Playback.translate_uri

    def translate_uri(self, uri):
        client = self.backend.bandcamp
        client.__dict__["get_album"] = orig_get_album.__get__(client, Client)
        client.__dict__["scrape"] = orig_scrape.__get__(client, Client)
        try:
            return orig_translate(self, uri)
        finally:
            client.__dict__.pop("get_album", None)
            client.__dict__.pop("scrape", None)

    Playback.translate_uri = translate_uri

    logger.info("mopidy-bandcamp disk cache installed at %s", CACHE_DIR)


_install()
