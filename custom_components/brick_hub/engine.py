"""Pure state machine for Brick Hub.

This module has no Home Assistant imports so it can be unit tested in
isolation and mirrored 1:1 by the iOS app's offline engine
(``ios/Shared/BrickEngine.swift``). Keep the two in sync.

Concepts
--------
* **Bricked** - the phone's selected apps are shielded.
* **Mode** - a named app selection that lives on the iPhone (Apple only lets
  the device see the actual apps). Home Assistant only knows ids and names.
* **Emergency unbrick** - a limited escape hatch. When used up (or any time
  some have been used) a *reset* can be requested; the allowance refills only
  after ``reset_hours`` (48h by default). No email, no support ticket.
* **Strict mode** - "manual" unbricks (a button in the HA UI or the app
  without scanning a brick tag) are refused. Tags, automations, timers,
  schedules and emergency unbricks still work.
"""

from __future__ import annotations

import hashlib
from collections import deque
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, timezone, tzinfo
from enum import StrEnum
from typing import Any

SESSION_HISTORY_DAYS = 90
EVENT_ID_MEMORY = 500
# Offline commands replayed from a phone are considered stale if Home
# Assistant changed state after they happened (with a little clock slack).
STALE_TOLERANCE = timedelta(seconds=2)


class Method(StrEnum):
    """How a brick/unbrick happened."""

    MANUAL = "manual"  # a person pressed a button (HA UI / app) without a tag
    TAG = "tag"  # a registered NFC brick tag was scanned
    AUTOMATION = "automation"  # an HA automation / script
    TIMER = "timer"  # a timed brick ran out
    SCHEDULE = "schedule"  # an on-device schedule started/ended
    EMERGENCY = "emergency"  # an emergency unbrick was spent


class Action(StrEnum):
    """Commands accepted by the engine."""

    BRICK = "brick"
    UNBRICK = "unbrick"
    TOGGLE = "toggle"
    EMERGENCY_UNBRICK = "emergency_unbrick"
    REQUEST_RESET = "request_emergency_reset"
    CANCEL_RESET = "cancel_emergency_reset"
    REGISTER_TAG = "register_tag"
    REMOVE_TAG = "remove_tag"


class BrickError(Exception):
    """A command was refused. ``code`` is stable and sent to clients."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


ERR_NOT_BRICKED = "not_bricked"
ERR_NO_EMERGENCY = "no_emergency_unbricks"
ERR_STRICT = "strict_mode"
ERR_UNKNOWN_TAG = "unknown_tag"
ERR_RESET_NOT_NEEDED = "reset_not_needed"
ERR_LOCKED = "locked_while_bricked"
ERR_UNKNOWN_MODE = "unknown_mode"
ERR_INVALID = "invalid"


def hash_tag(tag_id: str) -> str:
    """Normalise and hash a tag id so raw UIDs are never stored.

    ``04:a1:b2`` / ``04-A1-B2`` / ``04a1b2`` all hash the same, which lets the
    iPhone's CoreNFC UID match ESPHome / PN532 readers and HA tag ids.
    """
    norm = "".join(ch for ch in tag_id.strip().upper() if ch.isalnum())
    if not norm:
        raise BrickError(ERR_INVALID, "Empty tag id")
    return hashlib.sha256(f"brick_hub:{norm}".encode()).hexdigest()


def iso(value: datetime | None) -> str | None:
    return value.isoformat(timespec="milliseconds") if value else None


def _dt(value: str | None) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


@dataclass
class Settings:
    """User-tunable policy."""

    emergency_max: int = 5
    reset_hours: float = 48.0
    strict: bool = True
    auto_request_reset: bool = False
    tag_toggles: bool = True  # tag on an unbricked phone bricks it


@dataclass
class Session:
    """A completed brick session (for stats)."""

    start: datetime
    end: datetime
    mode_id: str | None
    ended_by: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "start": iso(self.start),
            "end": iso(self.end),
            "mode_id": self.mode_id,
            "ended_by": self.ended_by,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Session:
        return cls(
            start=_dt(data["start"]),  # type: ignore[arg-type]
            end=_dt(data["end"]),  # type: ignore[arg-type]
            mode_id=data.get("mode_id"),
            ended_by=data.get("ended_by", "unknown"),
        )


@dataclass
class Command:
    """A request to change state."""

    action: Action
    method: Method = Method.MANUAL
    mode_id: str | None = None
    duration: timedelta | None = None
    tag_id: str | None = None
    tag_name: str | None = None
    source: str = ""
    event_id: str | None = None
    # When the phone performed the action offline; None means "now".
    occurred_at: datetime | None = None


@dataclass
class Result:
    """Outcome of a command."""

    changed: bool
    note: str | None = None  # e.g. "stale", "duplicate"


@dataclass
class Engine:
    """The authoritative brick state."""

    settings: Settings = field(default_factory=Settings)
    bricked: bool = False
    mode_id: str | None = None
    bricked_since: datetime | None = None
    ends_at: datetime | None = None
    source: str | None = None
    last_method: str | None = None
    last_changed: datetime | None = None
    revision: int = 0
    emergency_remaining: int = 5
    emergency_reset_at: datetime | None = None
    tags: dict[str, str] = field(default_factory=dict)  # hash -> name
    modes: dict[str, str] = field(default_factory=dict)  # id -> name
    default_mode_id: str | None = None
    sessions: list[Session] = field(default_factory=list)
    _seen_events: deque[str] = field(
        default_factory=lambda: deque(maxlen=EVENT_ID_MEMORY)
    )

    # ------------------------------------------------------------------
    # construction / persistence
    # ------------------------------------------------------------------
    @classmethod
    def new(cls, settings: Settings) -> Engine:
        return cls(settings=settings, emergency_remaining=settings.emergency_max)

    def to_dict(self) -> dict[str, Any]:
        return {
            "bricked": self.bricked,
            "mode_id": self.mode_id,
            "bricked_since": iso(self.bricked_since),
            "ends_at": iso(self.ends_at),
            "source": self.source,
            "last_method": self.last_method,
            "last_changed": iso(self.last_changed),
            "revision": self.revision,
            "emergency_remaining": self.emergency_remaining,
            "emergency_reset_at": iso(self.emergency_reset_at),
            "tags": dict(self.tags),
            "modes": dict(self.modes),
            "default_mode_id": self.default_mode_id,
            "sessions": [s.to_dict() for s in self.sessions],
            "seen_events": list(self._seen_events),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any], settings: Settings) -> Engine:
        eng = cls(
            settings=settings,
            bricked=bool(data.get("bricked", False)),
            mode_id=data.get("mode_id"),
            bricked_since=_dt(data.get("bricked_since")),
            ends_at=_dt(data.get("ends_at")),
            source=data.get("source"),
            last_method=data.get("last_method"),
            last_changed=_dt(data.get("last_changed")),
            revision=int(data.get("revision", 0)),
            emergency_remaining=int(
                data.get("emergency_remaining", settings.emergency_max)
            ),
            emergency_reset_at=_dt(data.get("emergency_reset_at")),
            tags=dict(data.get("tags", {})),
            modes=dict(data.get("modes", {})),
            default_mode_id=data.get("default_mode_id"),
            sessions=[Session.from_dict(s) for s in data.get("sessions", [])],
        )
        eng._seen_events.extend(data.get("seen_events", []))
        eng.apply_settings(settings)
        return eng

    def apply_settings(self, settings: Settings) -> None:
        """Apply new settings without handing out free emergency unbricks.

        Lowering the maximum clamps what is left; raising it does *not*
        refill - only a completed reset does that.
        """
        self.settings = settings
        self.emergency_remaining = max(
            0, min(self.emergency_remaining, settings.emergency_max)
        )
        if self.emergency_remaining >= settings.emergency_max:
            self.emergency_reset_at = None

    # ------------------------------------------------------------------
    # commands
    # ------------------------------------------------------------------
    def handle(self, cmd: Command, now: datetime) -> Result:
        """Apply a command. Raises ``BrickError`` if refused."""
        if cmd.event_id:
            if cmd.event_id in self._seen_events:
                return Result(False, "duplicate")

        at = now
        stale = False
        if cmd.occurred_at is not None:
            at = min(cmd.occurred_at, now)  # never trust future timestamps
            if self.last_changed and at < self.last_changed - STALE_TOLERANCE:
                stale = True

        action = cmd.action
        if action is Action.TOGGLE:
            action = Action.UNBRICK if self.bricked else Action.BRICK

        if action is Action.BRICK:
            result = self._brick(cmd, at, stale)
        elif action is Action.UNBRICK:
            result = self._unbrick(cmd, at, stale)
        elif action is Action.EMERGENCY_UNBRICK:
            result = self._emergency(cmd, at, now, stale)
        elif action is Action.REQUEST_RESET:
            result = self._request_reset(now)
        elif action is Action.CANCEL_RESET:
            result = self._cancel_reset()
        elif action is Action.REGISTER_TAG:
            result = self._register_tag(cmd)
        elif action is Action.REMOVE_TAG:
            result = self._remove_tag(cmd)
        else:  # pragma: no cover - enum is exhaustive
            raise BrickError(ERR_INVALID, f"Unknown action {action}")

        if cmd.event_id:
            self._seen_events.append(cmd.event_id)
        if result.changed:
            self._bump(now)
        return result

    def _bump(self, now: datetime) -> None:
        self.revision += 1
        self.last_changed = now

    def _brick(self, cmd: Command, at: datetime, stale: bool) -> Result:
        if stale:
            return Result(False, "stale")
        mode_id = cmd.mode_id or self.mode_id or self.default_mode_id
        if cmd.mode_id and self.modes and cmd.mode_id not in self.modes:
            raise BrickError(ERR_UNKNOWN_MODE, f"Unknown mode {cmd.mode_id}")
        new_end = at + cmd.duration if cmd.duration else None

        if not self.bricked:
            self.bricked = True
            self.mode_id = mode_id
            self.bricked_since = at
            self.ends_at = new_end
            self.source = cmd.source or None
            self.last_method = cmd.method.value
            return Result(True)

        # Already bricked: you may make it stricter, never weaker.
        changed = False
        if cmd.mode_id and cmd.mode_id != self.mode_id:
            if self.settings.strict and cmd.method is Method.MANUAL:
                raise BrickError(
                    ERR_STRICT, "Strict mode: can't switch modes while bricked"
                )
            self.mode_id = cmd.mode_id
            changed = True
        if self.ends_at is not None:
            # Extending (or making it open-ended) is fine; shortening is not.
            if new_end is None or new_end > self.ends_at:
                self.ends_at = new_end
                changed = True
        return Result(changed)

    def _end_session(self, at: datetime, ended_by: Method) -> None:
        if self.bricked_since is not None:
            self.sessions.append(
                Session(self.bricked_since, max(at, self.bricked_since),
                        self.mode_id, ended_by.value)
            )
            cutoff = at - timedelta(days=SESSION_HISTORY_DAYS)
            self.sessions = [s for s in self.sessions if s.end >= cutoff]
        self.bricked = False
        self.bricked_since = None
        self.ends_at = None
        self.last_method = ended_by.value

    def _unbrick(self, cmd: Command, at: datetime, stale: bool) -> Result:
        if stale:
            return Result(False, "stale")
        if not self.bricked:
            return Result(False, "not_bricked")
        method = cmd.method
        if method is Method.TAG:
            self.require_known_tag(cmd.tag_id)
        elif method is Method.MANUAL and self.settings.strict:
            raise BrickError(
                ERR_STRICT,
                "Strict mode is on: scan your brick tag, wait for the timer, "
                "or use an emergency unbrick.",
            )
        elif method is Method.EMERGENCY:
            raise BrickError(ERR_INVALID, "Use emergency_unbrick")
        self.source = cmd.source or self.source
        self._end_session(at, method)
        return Result(True)

    def _emergency(
        self, cmd: Command, at: datetime, now: datetime, stale: bool
    ) -> Result:
        if self.emergency_remaining <= 0:
            raise BrickError(
                ERR_NO_EMERGENCY,
                "No emergency unbricks left. Request a reset - it completes "
                f"after {self.settings.reset_hours:g} hours.",
            )
        if not self.bricked and not stale:
            raise BrickError(ERR_NOT_BRICKED, "You're not bricked")
        # Always charge for an emergency unbrick, even a stale offline one:
        # it was already used on the phone.
        self.emergency_remaining -= 1
        if not stale and self.bricked:
            self.source = cmd.source or self.source
            self._end_session(at, Method.EMERGENCY)
        if (
            self.emergency_remaining == 0
            and self.settings.auto_request_reset
            and self.emergency_reset_at is None
        ):
            self._start_reset(now)
        return Result(True, "stale" if stale else None)

    def _start_reset(self, now: datetime) -> None:
        self.emergency_reset_at = now + timedelta(hours=self.settings.reset_hours)

    def _request_reset(self, now: datetime) -> Result:
        if self.emergency_remaining >= self.settings.emergency_max:
            raise BrickError(
                ERR_RESET_NOT_NEEDED, "You still have every emergency unbrick"
            )
        if self.emergency_reset_at is not None:
            return Result(False, "already_requested")
        self._start_reset(now)
        return Result(True)

    def _cancel_reset(self) -> Result:
        if self.emergency_reset_at is None:
            return Result(False)
        self.emergency_reset_at = None
        return Result(True)

    def _register_tag(self, cmd: Command) -> Result:
        if self.bricked:
            raise BrickError(ERR_LOCKED, "Can't add brick tags while bricked")
        tag_hash = hash_tag(cmd.tag_id or "")
        name = (cmd.tag_name or "").strip() or f"Brick {len(self.tags) + 1}"
        if self.tags.get(tag_hash) == name:
            return Result(False)
        self.tags[tag_hash] = name
        return Result(True)

    def _remove_tag(self, cmd: Command) -> Result:
        if self.bricked:
            raise BrickError(ERR_LOCKED, "Can't remove brick tags while bricked")
        key = cmd.tag_id or ""
        # Accept either the raw tag id or an already-hashed id (from the UI).
        if key not in self.tags:
            key = hash_tag(key)
        if key not in self.tags:
            raise BrickError(ERR_UNKNOWN_TAG, "Tag isn't registered")
        del self.tags[key]
        return Result(True)

    def is_known_tag(self, tag_id: str | None) -> bool:
        if not tag_id:
            return False
        try:
            return hash_tag(tag_id) in self.tags
        except BrickError:
            return False

    def require_known_tag(self, tag_id: str | None) -> None:
        if not self.is_known_tag(tag_id):
            raise BrickError(ERR_UNKNOWN_TAG, "That isn't one of your brick tags")

    # ------------------------------------------------------------------
    # time
    # ------------------------------------------------------------------
    def tick(self, now: datetime) -> bool:
        """Advance timers. Returns True if state changed."""
        changed = False
        if self.bricked and self.ends_at is not None and self.ends_at <= now:
            self._end_session(self.ends_at, Method.TIMER)
            changed = True
        if self.emergency_reset_at is not None and self.emergency_reset_at <= now:
            self.emergency_remaining = self.settings.emergency_max
            self.emergency_reset_at = None
            changed = True
        if changed:
            self._bump(now)
        return changed

    def next_deadline(self) -> datetime | None:
        times = [t for t in (self.ends_at if self.bricked else None,
                             self.emergency_reset_at) if t is not None]
        return min(times) if times else None

    def update_modes(self, modes: dict[str, str], now: datetime) -> bool:
        """Replace the mode ids/names reported by a phone."""
        if modes == self.modes:
            return False
        self.modes = dict(modes)
        if self.default_mode_id not in self.modes:
            self.default_mode_id = next(iter(self.modes), None)
        self._bump(now)
        return True

    def set_default_mode(self, mode_id: str | None, now: datetime) -> bool:
        """Mode used when something bricks without naming one."""
        if mode_id == self.default_mode_id:
            return False
        if mode_id and self.modes and mode_id not in self.modes:
            raise BrickError(ERR_UNKNOWN_MODE, f"Unknown mode {mode_id}")
        self.default_mode_id = mode_id
        self._bump(now)
        return True

    # ------------------------------------------------------------------
    # read models
    # ------------------------------------------------------------------
    def stats(self, now: datetime, tz: tzinfo) -> dict[str, Any]:
        sessions = list(self.sessions)
        if self.bricked and self.bricked_since is not None:
            sessions.append(Session(self.bricked_since, now, self.mode_id, ""))

        def overlap(start: datetime, end: datetime) -> float:
            total = 0.0
            for s in sessions:
                lo, hi = max(s.start, start), min(s.end, end)
                if hi > lo:
                    total += (hi - lo).total_seconds()
            return total

        def day_start(d: date) -> datetime:
            return datetime.combine(d, time.min, tzinfo=tz)

        today_date = now.astimezone(tz).date()
        today = overlap(day_start(today_date), now)
        week = overlap(now - timedelta(days=7), now)

        # Streak: consecutive local days (ending today, or yesterday if today
        # has nothing yet) with at least one minute bricked.
        streak = 0
        d = today_date if today >= 60 else today_date - timedelta(days=1)
        while streak <= SESSION_HISTORY_DAYS:
            if overlap(day_start(d), day_start(d + timedelta(days=1))) < 60:
                break
            streak += 1
            d -= timedelta(days=1)

        longest = max(
            ((s.end - s.start).total_seconds() for s in sessions), default=0.0
        )
        return {
            "today_seconds": round(today),
            "week_seconds": round(week),
            "streak_days": streak,
            "sessions_total": len(self.sessions),
            "longest_session_seconds": round(longest),
        }

    def public_state(self, now: datetime, tz: tzinfo) -> dict[str, Any]:
        """The state sent to phones (no tag hashes, no history)."""
        return {
            "revision": self.revision,
            "bricked": self.bricked,
            "mode_id": self.mode_id,
            "mode_name": self.modes.get(self.mode_id or ""),
            "default_mode_id": self.default_mode_id,
            "bricked_since": iso(self.bricked_since),
            "ends_at": iso(self.ends_at),
            "source": self.source,
            "last_method": self.last_method,
            "last_changed": iso(self.last_changed),
            "emergency_remaining": self.emergency_remaining,
            "emergency_max": self.settings.emergency_max,
            "emergency_reset_at": iso(self.emergency_reset_at),
            "reset_hours": self.settings.reset_hours,
            "strict": self.settings.strict,
            "tag_count": len(self.tags),
            "modes": [{"id": k, "name": v} for k, v in self.modes.items()],
            "stats": self.stats(now, tz),
            "server_time": iso(now),
        }
