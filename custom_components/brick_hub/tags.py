"""Tag id hashing - identical to TagHash.swift in the iOS app."""

from __future__ import annotations

import hashlib


def hash_tag(tag_id: str | None) -> str | None:
    """`04:a1:b2`, `04-A1-B2` and `04a1b2` all hash the same.

    The phone only shares hashes of its brick tags, so HA can recognise a
    scan from an ESPHome reader or the Companion app without storing UIDs.
    """
    norm = "".join(ch for ch in (tag_id or "").upper() if ch.isascii() and ch.isalnum())
    if not norm:
        return None
    return hashlib.sha256(f"brick_hub:{norm}".encode()).hexdigest()
