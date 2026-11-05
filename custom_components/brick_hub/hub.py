"""Brick Hub in Home Assistant: a remote control and mirror for phones.

The iPhone is the source of truth: it owns the brick state, the rules,
emergency unbricks, the reset timer and its tags. Home Assistant:

* sends **commands** (brick, unbrick, ...) to phones - by push and by
  long-poll - which expire after ``COMMAND_TTL_SECONDS`` if they don't arrive;
* **mirrors** what each phone reports, as entities;
* forwards ``tag_scanned`` events for the phone's brick tags (ESPHome NFC
  readers, the Companion app) to the phone, which decides what to do.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import CALLBACK_TYPE, Context, Event, HomeAssistant, callback
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.event import async_track_time_interval
from homeassistant.helpers.storage import Store
from homeassistant.util import dt as dt_util

from .apns import ApnsClient
from .const import (
    COMMAND_TTL_SECONDS,
    CONF_APNS_BUNDLE_ID,
    CONF_APNS_KEY,
    CONF_APNS_KEY_ID,
    CONF_APNS_TEAM_ID,
    CONF_PUSH_STYLE,
    DEFAULT_BUNDLE_ID,
    DOMAIN,
    EVENT_COMMAND_RESULT,
    EVENT_STATE_CHANGED,
    PUSH_ALERT,
    PUSH_OFF,
    PUSH_SILENT,
    SIGNAL_NEW_PHONE,
    SIGNAL_UPDATE,
    STORAGE_VERSION,
)
from .tags import hash_tag

_LOGGER = logging.getLogger(__name__)

ACTIONS = {
    "brick",
    "unbrick",
    "toggle",
    "emergency_unbrick",
    "request_emergency_reset",
    "cancel_emergency_reset",
    "register_tag",
    "remove_tag",
}

PUSH_TEXT = {
    "brick": "Brick requested",
    "unbrick": "Unbrick requested",
    "toggle": "Brick tag scanned",
    "emergency_unbrick": "Emergency unbrick requested",
    "request_emergency_reset": "Emergency reset requested",
    "cancel_emergency_reset": "Emergency reset cancelled",
    "register_tag": "Adding a brick tag",
    "remove_tag": "Removing a brick tag",
}


def method_from_context(context: Context | None) -> str:
    """A person in the HA UI is "manual"; automations are "automation".

    Scripts or automations a person runs by hand keep that person's user id,
    so they count as manual too. The phone refuses manual unbricks in strict
    mode; automations may end any brick.
    """
    return "manual" if context is not None and context.user_id else "automation"


def parse_dt(value: Any) -> datetime | None:
    if not value:
        return None
    parsed = dt_util.parse_datetime(str(value))
    return dt_util.as_utc(parsed) if parsed else None


@dataclass
class Phone:
    """What HA knows about one iPhone (all reported by the phone)."""

    device_id: str
    name: str = "iPhone"
    app_version: str = ""
    authorized: bool = False
    apns_token: str | None = None
    apns_sandbox: bool = False
    modes: dict[str, str] = field(default_factory=dict)  # id -> name
    tag_hashes: list[str] = field(default_factory=list)
    rules: dict[str, Any] = field(default_factory=dict)
    state: dict[str, Any] = field(default_factory=dict)
    stats: dict[str, Any] = field(default_factory=dict)
    last_report: datetime | None = None
    ha_mode: str | None = None  # mode HA uses when an automation names none
    last_result: dict[str, Any] | None = None

    # -- derived, so HA stays right between reports ------------------------
    @property
    def ends_at(self) -> datetime | None:
        return parse_dt(self.state.get("ends_at"))

    @property
    def bricked(self) -> bool:
        if not self.state.get("bricked"):
            return False
        ends = self.ends_at
        return not (ends is not None and ends <= dt_util.utcnow())

    @property
    def bricked_since(self) -> datetime | None:
        return parse_dt(self.state.get("bricked_since")) if self.bricked else None

    @property
    def emergency_reset_at(self) -> datetime | None:
        reset = parse_dt(self.state.get("emergency_reset_at"))
        return reset if reset and reset > dt_util.utcnow() else None

    @property
    def emergency_remaining(self) -> int | None:
        if "emergency_remaining" not in self.state:
            return None
        reset = parse_dt(self.state.get("emergency_reset_at"))
        if reset and reset <= dt_util.utcnow():
            return int(self.rules.get("emergency_max", self.state["emergency_remaining"]))
        return int(self.state["emergency_remaining"])

    @property
    def mode_name(self) -> str | None:
        return self.modes.get(self.state.get("mode_id") or "")

    def today_seconds(self) -> int:
        """Phone-reported time today, plus time since the report if bricked."""
        reported = int(self.stats.get("today_seconds", 0))
        if self.last_report is None:
            return reported
        now = dt_util.now()
        midnight = dt_util.start_of_local_day(now)
        report_local = dt_util.as_local(self.last_report)
        if report_local < midnight:
            reported = 0
        if self.bricked:
            since = self.bricked_since or self.last_report
            start = max(self.last_report, dt_util.as_utc(midnight), since)
            reported += max(0, int((dt_util.utcnow() - start).total_seconds()))
        return reported

    def to_store(self) -> dict[str, Any]:
        return {
            "device_id": self.device_id,
            "name": self.name,
            "app_version": self.app_version,
            "authorized": self.authorized,
            "apns_token": self.apns_token,
            "apns_sandbox": self.apns_sandbox,
            "modes": self.modes,
            "tag_hashes": self.tag_hashes,
            "rules": self.rules,
            "state": self.state,
            "stats": self.stats,
            "last_report": self.last_report.isoformat() if self.last_report else None,
            "ha_mode": self.ha_mode,
        }

    @classmethod
    def from_store(cls, data: dict[str, Any]) -> Phone:
        phone = cls(device_id=data["device_id"])
        for key in (
            "name", "app_version", "authorized", "apns_token", "apns_sandbox",
            "modes", "tag_hashes", "rules", "state", "stats", "ha_mode",
        ):
            if key in data and data[key] is not None:
                setattr(phone, key, data[key])
        phone.last_report = parse_dt(data.get("last_report"))
        return phone


class BrickHub:
    """Remote control + mirror for all linked phones."""

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self.store: Store[dict[str, Any]] = Store(
            hass, STORAGE_VERSION, f"{DOMAIN}.{entry.entry_id}"
        )
        self.phones: dict[str, Phone] = {}
        self.pending: dict[str, list[dict[str, Any]]] = {}
        self.apns: ApnsClient | None = None
        self._waiters: dict[str, asyncio.Event] = {}
        self._unsubs: list[CALLBACK_TYPE] = []

    # ------------------------------------------------------------------
    # lifecycle
    # ------------------------------------------------------------------
    async def async_setup(self) -> None:
        data = await self.store.async_load() or {}
        for raw in data.get("phones", []):
            phone = Phone.from_store(raw)
            self.phones[phone.device_id] = phone
        self._setup_apns()
        self._unsubs.append(
            self.hass.bus.async_listen("tag_scanned", self._handle_tag_scanned)
        )
        self._unsubs.append(
            async_track_time_interval(self.hass, self._handle_tick, timedelta(seconds=30))
        )

    async def async_unload(self) -> None:
        for unsub in self._unsubs:
            unsub()
        self._unsubs.clear()
        for event in self._waiters.values():
            event.set()
        if self.apns:
            await self.apns.close()

    def _setup_apns(self) -> None:
        conf = {**self.entry.data, **self.entry.options}
        team, key_id, key = (
            conf.get(CONF_APNS_TEAM_ID),
            conf.get(CONF_APNS_KEY_ID),
            conf.get(CONF_APNS_KEY),
        )
        if team and key_id and key:
            self.apns = ApnsClient(
                self.hass, team, key_id, key,
                conf.get(CONF_APNS_BUNDLE_ID) or DEFAULT_BUNDLE_ID,
            )

    @property
    def push_style(self) -> str:
        conf = {**self.entry.data, **self.entry.options}
        return conf.get(CONF_PUSH_STYLE, PUSH_ALERT)

    async def async_save(self) -> None:
        await self.store.async_save(
            {"phones": [p.to_store() for p in self.phones.values()]}
        )

    # ------------------------------------------------------------------
    # commands (HA -> phone)
    # ------------------------------------------------------------------
    def resolve_phones(self, device_ids: list[str] | None) -> list[Phone]:
        """Phone device ids (ours), or every phone if none given."""
        if not device_ids:
            return list(self.phones.values())
        return [self.phones[d] for d in device_ids if d in self.phones]

    async def async_send(
        self,
        phones: list[Phone],
        action: str,
        *,
        context: Context | None = None,
        method: str | None = None,
        mode: str | None = None,
        duration: timedelta | None = None,
        tag_id: str | None = None,
        tag_name: str | None = None,
        source: str | None = None,
    ) -> list[str]:
        """Queue a command for each phone and push it. Returns command ids."""
        if action not in ACTIONS:
            raise ValueError(f"Unknown action {action}")
        now = dt_util.utcnow()
        expires = now + timedelta(seconds=COMMAND_TTL_SECONDS)
        if source is None:
            source = "Home Assistant" if context and context.user_id else "Automation"
        ids = []
        for phone in phones:
            cmd: dict[str, Any] = {
                "id": uuid.uuid4().hex,
                "action": action,
                "method": method or method_from_context(context),
                "source": source[:80],
                "issued_at": now.isoformat(),
                "expires_at": expires.isoformat(),
            }
            wanted = mode or (phone.ha_mode if action in ("brick", "toggle") else None)
            if wanted:
                cmd.update(self._mode_fields(phone, wanted))
            if duration:
                cmd["duration_minutes"] = duration.total_seconds() / 60
            if tag_id:
                cmd["tag_id"] = tag_id
            if tag_name:
                cmd["tag_name"] = tag_name
            self.pending.setdefault(phone.device_id, []).append(cmd)
            ids.append(cmd["id"])
            self._wake(phone.device_id)
            self.hass.async_create_task(self._push(phone, cmd, expires))
        return ids

    @staticmethod
    def _mode_fields(phone: Phone, wanted: str) -> dict[str, str]:
        if wanted in phone.modes:
            return {"mode_id": wanted}
        for mode_id, name in phone.modes.items():
            if name.casefold() == wanted.casefold():
                return {"mode_id": mode_id}
        return {"mode_name": wanted}  # the phone will say it doesn't know it

    def pending_for(self, device_id: str) -> list[dict[str, Any]]:
        now = dt_util.utcnow()
        return [
            c for c in self.pending.get(device_id, [])
            if parse_dt(c["expires_at"]) > now
        ]

    async def wait_for_commands(self, device_id: str, timeout: float) -> list[dict[str, Any]]:
        """Long-poll: return as soon as there's a command for this phone."""
        if not self.pending_for(device_id) and timeout > 0:
            event = self._waiters.setdefault(device_id, asyncio.Event())
            try:
                async with asyncio.timeout(timeout):
                    await event.wait()
            except TimeoutError:
                pass
        return self.pending_for(device_id)

    @callback
    def _wake(self, device_id: str) -> None:
        if event := self._waiters.pop(device_id, None):
            event.set()

    @callback
    def _handle_tag_scanned(self, event: Event) -> None:
        """Forward scans of a phone's brick tags to that phone."""
        tag_hash = hash_tag(event.data.get("tag_id"))
        if tag_hash is None:
            return
        phones = [p for p in self.phones.values() if tag_hash in p.tag_hashes]
        if phones:
            self.hass.async_create_task(
                self.async_send(
                    phones, "toggle", method="tag", tag_id=event.data["tag_id"],
                    source="Brick tag", context=event.context,
                )
            )

    async def _handle_tick(self, _now: datetime) -> None:
        """Drop expired commands (reporting them) and refresh entities."""
        now = dt_util.utcnow()
        for device_id, cmds in list(self.pending.items()):
            keep = []
            for cmd in cmds:
                if parse_dt(cmd["expires_at"]) > now:
                    keep.append(cmd)
                    continue
                self._fire_result(
                    self.phones.get(device_id), cmd,
                    {"ok": False, "code": "no_response",
                     "message": "The phone didn't confirm this in time. If it never "
                                "received it, it was dropped."},
                )
            self.pending[device_id] = keep
        async_dispatcher_send(self.hass, SIGNAL_UPDATE)

    # ------------------------------------------------------------------
    # reports (phone -> HA)
    # ------------------------------------------------------------------
    async def async_report(self, payload: dict[str, Any]) -> list[dict[str, Any]]:
        """Store what the phone told us; return commands waiting for it."""
        device_id = str(payload["device_id"])
        is_new = device_id not in self.phones
        phone = self.phones.setdefault(device_id, Phone(device_id=device_id))
        old_rev = phone.state.get("revision")
        old_bricked = phone.bricked

        for key in ("name", "app_version", "authorized", "apns_token", "apns_sandbox",
                    "rules", "stats"):
            if key in payload and payload[key] is not None:
                setattr(phone, key, payload[key])
        if isinstance(payload.get("state"), dict):
            phone.state = payload["state"]
        if isinstance(payload.get("modes"), list):
            phone.modes = {
                str(m["id"]): str(m.get("name") or m["id"])
                for m in payload["modes"] if isinstance(m, dict) and m.get("id")
            }
            if phone.ha_mode not in phone.modes:
                phone.ha_mode = next(iter(phone.modes), None)
        if isinstance(payload.get("tag_hashes"), list):
            phone.tag_hashes = [str(h) for h in payload["tag_hashes"]]
        phone.last_report = dt_util.utcnow()

        # Results of earlier commands: fire events, stop re-sending them.
        acked = set()
        for result in payload.get("results") or []:
            if not isinstance(result, dict) or "id" not in result:
                continue
            acked.add(result["id"])
            cmd = next((c for c in self.pending.get(device_id, []) if c["id"] == result["id"]), None)
            if result.get("code") != "duplicate":
                self._fire_result(phone, cmd or {"id": result["id"]}, result)
        if acked:
            self.pending[device_id] = [
                c for c in self.pending.get(device_id, []) if c["id"] not in acked
            ]

        await self.async_save()
        if is_new:
            async_dispatcher_send(self.hass, SIGNAL_NEW_PHONE, phone)
        async_dispatcher_send(self.hass, SIGNAL_UPDATE)
        if phone.state.get("revision") != old_rev and not is_new:
            self.hass.bus.async_fire(
                EVENT_STATE_CHANGED,
                {
                    "device_id": device_id,
                    "phone": phone.name,
                    "bricked": phone.bricked,
                    "was_bricked": old_bricked,
                    "mode": phone.mode_name,
                    "method": phone.state.get("last_method"),
                    "source": phone.state.get("source"),
                    "ends_at": phone.state.get("ends_at"),
                    "emergency_remaining": phone.emergency_remaining,
                },
            )
        return self.pending_for(device_id)

    @callback
    def _fire_result(self, phone: Phone | None, cmd: dict[str, Any], result: dict[str, Any]) -> None:
        data = {
            "device_id": phone.device_id if phone else None,
            "phone": phone.name if phone else None,
            "command_id": cmd.get("id"),
            "action": cmd.get("action"),
            "ok": bool(result.get("ok")),
            "changed": bool(result.get("changed")),
            "code": result.get("code"),
            "message": result.get("message"),
        }
        if phone:
            phone.last_result = data
        self.hass.bus.async_fire(EVENT_COMMAND_RESULT, data)

    async def async_set_ha_mode(self, phone: Phone, mode_id: str | None) -> None:
        phone.ha_mode = mode_id
        await self.async_save()
        async_dispatcher_send(self.hass, SIGNAL_UPDATE)

    # ------------------------------------------------------------------
    # push
    # ------------------------------------------------------------------
    async def _push(self, phone: Phone, cmd: dict[str, Any], expires: datetime) -> None:
        style = self.push_style
        if self.apns is None or style == PUSH_OFF or not phone.apns_token:
            return
        background = style == PUSH_SILENT
        if background:
            payload: dict[str, Any] = {"aps": {"content-available": 1}, "brick_cmd": cmd}
        else:
            # The phone's notification extension runs the command and
            # rewrites this text to say what actually happened.
            payload = {
                "aps": {
                    "alert": {"title": "Brick Hub", "body": PUSH_TEXT.get(cmd["action"], "Command")},
                    "mutable-content": 1,
                    "thread-id": "brick",
                },
                "brick_cmd": cmd,
            }
        result = await self.apns.send(
            phone.apns_token,
            payload,
            sandbox=phone.apns_sandbox,
            background=background,
            expires_at=int(expires.timestamp()),
        )
        if result.token_dead:
            phone.apns_token = None
            await self.async_save()
