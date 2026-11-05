"""REST API used by the Brick Hub iOS app.

All endpoints require a Home Assistant long-lived access token
(``Authorization: Bearer ...``), exactly like the rest of the HA API.

GET  /api/brick_hub/state?since=<rev>&wait=<seconds>
     Returns the public state. With ``since`` + ``wait`` it long-polls until
     the revision changes (max 55s), so a foregrounded app updates instantly.
POST /api/brick_hub/command
     {"action": "brick", "mode_id": "...", "duration_minutes": 30,
      "method": "tag", "tag_id": "04-A1-..", "event_id": "uuid",
      "occurred_at": "iso8601", "device_id": "..."}
POST /api/brick_hub/device
     Registration / heartbeat: name, APNs token, modes, Screen Time
     authorisation and the last revision the phone applied.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from http import HTTPStatus
from typing import Any

from aiohttp import web

from homeassistant.components.http import HomeAssistantView
from homeassistant.core import Context, HomeAssistant

from .const import API_BASE, DOMAIN, LONG_POLL_MAX_SECONDS
from .engine import Action, BrickError, Command
from .hub import BrickHub


def _hub(hass: HomeAssistant) -> BrickHub | None:
    hubs: dict[str, BrickHub] = hass.data.get(DOMAIN, {})
    return next(iter(hubs.values()), None)


def _not_ready() -> web.Response:
    return web.json_response(
        {"ok": False, "code": "not_ready", "message": "Brick Hub isn't set up"},
        status=HTTPStatus.SERVICE_UNAVAILABLE,
    )


def _bad(message: str) -> web.Response:
    return web.json_response(
        {"ok": False, "code": "invalid", "message": message},
        status=HTTPStatus.BAD_REQUEST,
    )


class BrickStateView(HomeAssistantView):
    """Current state, optionally long-polled."""

    url = f"{API_BASE}/state"
    name = "api:brick_hub:state"

    async def get(self, request: web.Request) -> web.Response:
        hass: HomeAssistant = request.app["hass"]
        hub = _hub(hass)
        if hub is None:
            return _not_ready()
        since = request.query.get("since")
        if since is not None:
            try:
                wait = min(float(request.query.get("wait", 25)), LONG_POLL_MAX_SECONDS)
                await hub.wait_for_change(int(since), max(wait, 0))
            except ValueError:
                return _bad("since/wait must be numbers")
        return web.json_response({"ok": True, "state": hub.public_state()})


class BrickCommandView(HomeAssistantView):
    """Run a command from the phone."""

    url = f"{API_BASE}/command"
    name = "api:brick_hub:command"

    async def post(self, request: web.Request) -> web.Response:
        hass: HomeAssistant = request.app["hass"]
        hub = _hub(hass)
        if hub is None:
            return _not_ready()
        try:
            body: dict[str, Any] = await request.json()
            action = Action(body["action"])
        except (ValueError, KeyError):
            return _bad("Missing or unknown action")

        duration = None
        if body.get("duration_minutes"):
            try:
                duration = timedelta(minutes=float(body["duration_minutes"]))
            except (TypeError, ValueError):
                return _bad("duration_minutes must be a number")
        occurred_at = None
        if body.get("occurred_at"):
            try:
                occurred_at = datetime.fromisoformat(body["occurred_at"])
            except ValueError:
                return _bad("occurred_at must be ISO 8601")
            if occurred_at.tzinfo is None:
                return _bad("occurred_at needs a timezone")

        device_id = body.get("device_id")
        device_name = (hub.devices.get(device_id or "", {}).get("name")) or "iPhone"
        cmd = Command(
            action=action,
            method=hub.sanitize_device_method(body.get("method"), action),
            mode_id=hub.resolve_mode(body.get("mode_id")),
            duration=duration,
            tag_id=body.get("tag_id"),
            tag_name=body.get("tag_name"),
            source=str(body.get("source") or device_name)[:80],
            event_id=body.get("event_id"),
            occurred_at=occurred_at,
        )
        user = request.get("hass_user")
        context = Context(user_id=user.id if user else None)
        try:
            result = await hub.async_command(
                cmd, origin_device=device_id, context=context
            )
        except BrickError as err:
            return web.json_response(
                {
                    "ok": False,
                    "code": err.code,
                    "message": err.message,
                    "state": hub.public_state(),
                },
                status=HTTPStatus.CONFLICT,
            )
        return web.json_response(
            {
                "ok": True,
                "changed": result.changed,
                "note": result.note,
                "state": hub.public_state(),
            }
        )


class BrickDeviceView(HomeAssistantView):
    """Phone registration and heartbeat."""

    url = f"{API_BASE}/device"
    name = "api:brick_hub:device"

    async def post(self, request: web.Request) -> web.Response:
        hass: HomeAssistant = request.app["hass"]
        hub = _hub(hass)
        if hub is None:
            return _not_ready()
        try:
            body: dict[str, Any] = await request.json()
        except ValueError:
            return _bad("Body must be JSON")
        if not body.get("device_id"):
            return _bad("device_id is required")
        await hub.async_update_device(body)
        return web.json_response({"ok": True, "state": hub.public_state()})


def async_register_views(hass: HomeAssistant) -> None:
    """Register the views once per HA run."""
    if hass.data.get(f"{DOMAIN}_views"):
        return
    hass.data[f"{DOMAIN}_views"] = True
    hass.http.register_view(BrickStateView())
    hass.http.register_view(BrickCommandView())
    hass.http.register_view(BrickDeviceView())
