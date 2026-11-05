"""Home Assistant side of Brick Hub: storage, timers, events and pushes."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import CALLBACK_TYPE, Context, Event, HomeAssistant, callback
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.event import (
    async_track_point_in_utc_time,
    async_track_time_interval,
)
from homeassistant.helpers.storage import Store
from homeassistant.util import dt as dt_util

from .apns import ApnsClient
from .const import (
    CONF_APNS_BUNDLE_ID,
    CONF_APNS_KEY,
    CONF_APNS_KEY_ID,
    CONF_APNS_TEAM_ID,
    CONF_AUTO_RESET,
    CONF_EMERGENCY_MAX,
    CONF_PUSH_STYLE,
    CONF_RESET_HOURS,
    CONF_STRICT,
    CONF_TAG_TOGGLES,
    DEFAULT_AUTO_RESET,
    DEFAULT_BUNDLE_ID,
    DEFAULT_EMERGENCY_MAX,
    DEFAULT_RESET_HOURS,
    DEFAULT_STRICT,
    DEFAULT_TAG_TOGGLES,
    DOMAIN,
    EVENT_COMMAND_REFUSED,
    EVENT_STATE_CHANGED,
    PUSH_ALERT,
    PUSH_OFF,
    PUSH_SILENT,
    SIGNAL_UPDATE,
    STORAGE_VERSION,
)
from .engine import (
    Action,
    BrickError,
    Command,
    Engine,
    Method,
    Result,
    Settings,
    hash_tag,
    iso,
)

_LOGGER = logging.getLogger(__name__)

# A phone can claim a timer ended slightly before HA's clock agrees.
CLOCK_SLACK = timedelta(seconds=30)


def settings_from_entry(entry: ConfigEntry) -> Settings:
    """Build engine settings from entry data + options."""
    conf = {**entry.data, **entry.options}
    return Settings(
        emergency_max=int(conf.get(CONF_EMERGENCY_MAX, DEFAULT_EMERGENCY_MAX)),
        reset_hours=float(conf.get(CONF_RESET_HOURS, DEFAULT_RESET_HOURS)),
        strict=bool(conf.get(CONF_STRICT, DEFAULT_STRICT)),
        auto_request_reset=bool(conf.get(CONF_AUTO_RESET, DEFAULT_AUTO_RESET)),
        tag_toggles=bool(conf.get(CONF_TAG_TOGGLES, DEFAULT_TAG_TOGGLES)),
    )


def method_from_context(context: Context | None) -> Method:
    """Service calls made by a logged-in person are "manual".

    Automations run with a context that has no user. Scripts or automations
    a person runs by hand from the UI keep that person's user id, so they
    count as manual too - you can't dodge strict mode with a one-line script.
    """
    if context is not None and context.user_id:
        return Method.MANUAL
    return Method.AUTOMATION


class BrickHub:
    """Owns the engine for one config entry."""

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self.store: Store[dict[str, Any]] = Store(
            hass, STORAGE_VERSION, f"{DOMAIN}.{entry.entry_id}"
        )
        self.engine = Engine.new(settings_from_entry(entry))
        self.devices: dict[str, dict[str, Any]] = {}
        self.apns: ApnsClient | None = None
        self._changed = asyncio.Event()
        self._unsubs: list[CALLBACK_TYPE] = []
        self._deadline_unsub: CALLBACK_TYPE | None = None
        self._lock = asyncio.Lock()

    # ------------------------------------------------------------------
    # lifecycle
    # ------------------------------------------------------------------
    async def async_setup(self) -> None:
        data = await self.store.async_load()
        settings = settings_from_entry(self.entry)
        if data:
            self.engine = Engine.from_dict(data.get("engine", {}), settings)
            self.devices = data.get("devices", {})
        self._setup_apns()
        self._unsubs.append(
            self.hass.bus.async_listen("tag_scanned", self._handle_tag_scanned)
        )
        self._unsubs.append(
            async_track_time_interval(
                self.hass, self._handle_minute, timedelta(minutes=1)
            )
        )
        # Catch up on anything that expired while HA was down.
        if self.engine.tick(dt_util.utcnow()):
            await self._after_change(None, origin_device=None)
        self._schedule_deadline()

    async def async_unload(self) -> None:
        for unsub in self._unsubs:
            unsub()
        self._unsubs.clear()
        if self._deadline_unsub:
            self._deadline_unsub()
            self._deadline_unsub = None
        self._changed.set()  # release long-pollers
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
                self.hass,
                team,
                key_id,
                key,
                conf.get(CONF_APNS_BUNDLE_ID) or DEFAULT_BUNDLE_ID,
            )

    @property
    def push_style(self) -> str:
        conf = {**self.entry.data, **self.entry.options}
        return conf.get(CONF_PUSH_STYLE, PUSH_ALERT)

    # ------------------------------------------------------------------
    # commands
    # ------------------------------------------------------------------
    async def async_command(
        self,
        cmd: Command,
        *,
        origin_device: str | None = None,
        context: Context | None = None,
    ) -> Result:
        """Run a command. Raises ``BrickError`` (and fires an event) if refused."""
        async with self._lock:
            now = dt_util.utcnow()
            self.engine.tick(now)
            try:
                result = self.engine.handle(cmd, now)
            except BrickError as err:
                self.hass.bus.async_fire(
                    EVENT_COMMAND_REFUSED,
                    {
                        "action": cmd.action.value,
                        "method": cmd.method.value,
                        "code": err.code,
                        "message": err.message,
                        "source": cmd.source,
                    },
                    context=context,
                )
                raise
            if result.changed:
                await self._after_change(context, origin_device=origin_device)
            return result

    def resolve_mode(self, value: str | None) -> str | None:
        """Accept a mode id or a mode name (case-insensitive)."""
        if not value:
            return None
        if value in self.engine.modes:
            return value
        for mode_id, name in self.engine.modes.items():
            if name.casefold() == value.casefold():
                return mode_id
        return value  # let the engine produce a proper error

    async def async_set_default_mode(self, mode_id: str | None) -> None:
        async with self._lock:
            if self.engine.set_default_mode(mode_id, dt_util.utcnow()):
                await self._after_change(None, origin_device=None)

    @callback
    def _handle_tag_scanned(self, event: Event) -> None:
        """Any tag reader HA knows about (Companion app, ESPHome PN532...)."""
        tag_id = event.data.get("tag_id")
        if not self.engine.is_known_tag(tag_id):
            return
        if self.engine.bricked:
            action = Action.UNBRICK
        elif self.engine.settings.tag_toggles:
            action = Action.BRICK
        else:
            return
        source = f"Tag {self.engine.tags.get(_safe_hash(tag_id), '')}".strip()
        self.hass.async_create_task(
            self._run_quietly(
                Command(action, Method.TAG, tag_id=tag_id, source=source),
                event.context,
            )
        )

    async def _run_quietly(self, cmd: Command, context: Context | None) -> None:
        try:
            await self.async_command(cmd, context=context)
        except BrickError as err:
            _LOGGER.info("Brick tag command refused: %s", err.message)

    # ------------------------------------------------------------------
    # timers
    # ------------------------------------------------------------------
    @callback
    def _schedule_deadline(self) -> None:
        if self._deadline_unsub:
            self._deadline_unsub()
            self._deadline_unsub = None
        deadline = self.engine.next_deadline()
        if deadline is not None:
            self._deadline_unsub = async_track_point_in_utc_time(
                self.hass, self._handle_deadline, deadline
            )

    async def _handle_deadline(self, _now: datetime) -> None:
        self._deadline_unsub = None
        await self._tick()

    async def _handle_minute(self, _now: datetime) -> None:
        await self._tick()
        # Stats (time bricked today etc.) move every minute.
        async_dispatcher_send(self.hass, SIGNAL_UPDATE)

    async def _tick(self) -> None:
        async with self._lock:
            if self.engine.tick(dt_util.utcnow()):
                await self._after_change(None, origin_device=None)

    # ------------------------------------------------------------------
    # devices (iPhones)
    # ------------------------------------------------------------------
    async def async_update_device(self, payload: dict[str, Any]) -> None:
        """Registration + heartbeat from the iOS app."""
        device_id = str(payload["device_id"])
        dev = self.devices.setdefault(device_id, {})
        for key in (
            "name",
            "apns_token",
            "apns_sandbox",
            "authorized",
            "app_version",
            "applied_revision",
        ):
            if key in payload:
                dev[key] = payload[key]
        dev["last_seen"] = dt_util.utcnow().isoformat()
        async with self._lock:
            modes = payload.get("modes")
            changed = False
            if isinstance(modes, list):
                changed = self.engine.update_modes(
                    {
                        str(m["id"]): str(m.get("name") or m["id"])
                        for m in modes
                        if isinstance(m, dict) and m.get("id")
                    },
                    dt_util.utcnow(),
                )
            if changed:
                await self._after_change(None, origin_device=device_id)
            else:
                await self._save()
                async_dispatcher_send(self.hass, SIGNAL_UPDATE)

    def device_sync_status(self) -> dict[str, Any]:
        rev = self.engine.revision
        return {
            dev.get("name") or dev_id: {
                "in_sync": dev.get("applied_revision") == rev,
                "screen_time_authorized": dev.get("authorized", False),
                "last_seen": dev.get("last_seen"),
                "push": bool(dev.get("apns_token")),
            }
            for dev_id, dev in self.devices.items()
        }

    def sanitize_device_method(self, method: str | None, action: Action) -> Method:
        """Phones may only claim methods they can actually prove.

        * ``tag`` is checked against registered tags by the engine.
        * ``timer`` is only honoured if the timer really has run out.
        * ``schedule`` can only end a brick a schedule started.
        Everything else is ``manual`` (and refused in strict mode).
        """
        if method == Method.TAG:
            return Method.TAG
        if action in (Action.UNBRICK, Action.TOGGLE) and self.engine.bricked:
            now = dt_util.utcnow()
            if (
                method == Method.TIMER
                and self.engine.ends_at is not None
                and self.engine.ends_at <= now + CLOCK_SLACK
            ):
                return Method.TIMER
            if method == Method.SCHEDULE and self.engine.last_method == Method.SCHEDULE:
                return Method.SCHEDULE
            return Method.MANUAL
        if method == Method.SCHEDULE:
            return Method.SCHEDULE
        return Method.MANUAL

    # ------------------------------------------------------------------
    # change propagation
    # ------------------------------------------------------------------
    def public_state(self) -> dict[str, Any]:
        return self.engine.public_state(
            dt_util.utcnow(), dt_util.get_default_time_zone()
        )

    async def wait_for_change(self, since: int, timeout: float) -> None:
        """Long-poll helper for phones in the foreground."""
        if self.engine.revision != since:
            return
        event = self._changed
        try:
            async with asyncio.timeout(timeout):
                await event.wait()
        except TimeoutError:
            pass

    async def _save(self) -> None:
        await self.store.async_save(
            {"engine": self.engine.to_dict(), "devices": self.devices}
        )

    async def _after_change(
        self, context: Context | None, *, origin_device: str | None
    ) -> None:
        await self._save()
        self._schedule_deadline()
        # Wake long-pollers, then arm a fresh event for the next change.
        self._changed.set()
        self._changed = asyncio.Event()
        async_dispatcher_send(self.hass, SIGNAL_UPDATE)
        eng = self.engine
        self.hass.bus.async_fire(
            EVENT_STATE_CHANGED,
            {
                "bricked": eng.bricked,
                "mode_id": eng.mode_id,
                "mode": eng.modes.get(eng.mode_id or ""),
                "method": eng.last_method,
                "source": eng.source,
                "ends_at": iso(eng.ends_at),
                "emergency_remaining": eng.emergency_remaining,
                "revision": eng.revision,
            },
            context=context,
        )
        self.hass.async_create_task(self._push_all(origin_device))

    # ------------------------------------------------------------------
    # push
    # ------------------------------------------------------------------
    def _push_payload(self, background: bool) -> dict[str, Any]:
        eng = self.engine
        state = {
            "rev": eng.revision,
            "bricked": eng.bricked,
            "mode_id": eng.mode_id,
            "since": iso(eng.bricked_since),
            "ends_at": iso(eng.ends_at),
            "em": eng.emergency_remaining,
            "em_max": eng.settings.emergency_max,
            "em_reset": (
                iso(eng.emergency_reset_at)
            ),
            "strict": eng.settings.strict,
            "src": (eng.source or "")[:60],
            "method": eng.last_method,
        }
        if background:
            return {"aps": {"content-available": 1}, "brick": state}
        mode = eng.modes.get(eng.mode_id or "", "")
        if eng.bricked:
            title = "Bricked"
            parts = [mode] if mode else []
            if eng.ends_at:
                local = dt_util.as_local(eng.ends_at)
                parts.append(f"until {local.strftime('%-I:%M %p').lower()}")
            if eng.source:
                parts.append(f"by {eng.source}")
            body = " · ".join(parts) or "Your apps are blocked"
        else:
            title = "Unbricked"
            body = {
                "timer": "Time's up - apps are back",
                "emergency": f"Emergency unbrick used ({eng.emergency_remaining} left)",
                "tag": "Brick tag scanned",
            }.get(eng.last_method or "", "Your apps are back")
        return {
            "aps": {
                "alert": {"title": title, "body": body},
                "mutable-content": 1,
                "content-available": 1,
                "thread-id": "brick",
                "interruption-level": "active",
            },
            "brick": state,
        }

    async def _push_all(self, origin_device: str | None) -> None:
        style = self.push_style
        if self.apns is None or style == PUSH_OFF:
            return
        background = style == PUSH_SILENT
        payload = self._push_payload(background)
        dirty = False
        for dev_id, dev in self.devices.items():
            token = dev.get("apns_token")
            if not token or dev_id == origin_device:
                continue
            result = await self.apns.send(
                token,
                payload,
                sandbox=bool(dev.get("apns_sandbox")),
                background=background,
                collapse_id="brick-state",
            )
            if result.token_dead:
                dev.pop("apns_token", None)
                dirty = True
        if dirty:
            await self._save()



def _safe_hash(tag_id: str | None) -> str:
    try:
        return hash_tag(tag_id or "")
    except BrickError:
        return ""
