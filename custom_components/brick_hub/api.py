"""REST API used by the Brick Hub iOS app.

All endpoints need a Home Assistant long-lived access token
(``Authorization: Bearer ...``), like the rest of the HA API.

POST /api/brick_hub/report
     The phone reports its state, rules, modes, tag hashes and the results of
     commands it ran. Returns commands waiting for it.
GET  /api/brick_hub/commands?device_id=<id>&wait=<seconds>
     Long-poll for commands while the app is open (max 55 s).
"""

from __future__ import annotations

from http import HTTPStatus
from typing import Any

from aiohttp import web

from homeassistant.components.http import HomeAssistantView
from homeassistant.core import HomeAssistant

from .const import API_BASE, DOMAIN, LONG_POLL_MAX_SECONDS
from .hub import BrickHub


def _hub(hass: HomeAssistant) -> BrickHub | None:
    hubs: dict[str, BrickHub] = hass.data.get(DOMAIN, {})
    return next(iter(hubs.values()), None)


def _error(status: HTTPStatus, code: str, message: str) -> web.Response:
    return web.json_response({"ok": False, "code": code, "message": message}, status=status)


class BrickReportView(HomeAssistantView):
    """Phone -> HA: state report (and command results)."""

    url = f"{API_BASE}/report"
    name = "api:brick_hub:report"

    async def post(self, request: web.Request) -> web.Response:
        hub = _hub(request.app["hass"])
        if hub is None:
            return _error(HTTPStatus.SERVICE_UNAVAILABLE, "not_ready", "Brick Hub isn't set up")
        try:
            body: dict[str, Any] = await request.json()
        except ValueError:
            return _error(HTTPStatus.BAD_REQUEST, "invalid", "Body must be JSON")
        if not isinstance(body, dict) or not body.get("device_id"):
            return _error(HTTPStatus.BAD_REQUEST, "invalid", "device_id is required")
        commands = await hub.async_report(body)
        return web.json_response({"ok": True, "commands": commands})


class BrickCommandsView(HomeAssistantView):
    """HA -> phone: commands, long-polled."""

    url = f"{API_BASE}/commands"
    name = "api:brick_hub:commands"

    async def get(self, request: web.Request) -> web.Response:
        hub = _hub(request.app["hass"])
        if hub is None:
            return _error(HTTPStatus.SERVICE_UNAVAILABLE, "not_ready", "Brick Hub isn't set up")
        device_id = request.query.get("device_id")
        if not device_id:
            return _error(HTTPStatus.BAD_REQUEST, "invalid", "device_id is required")
        try:
            wait = min(max(float(request.query.get("wait", 0)), 0), LONG_POLL_MAX_SECONDS)
        except ValueError:
            return _error(HTTPStatus.BAD_REQUEST, "invalid", "wait must be a number")
        commands = await hub.wait_for_commands(device_id, wait)
        return web.json_response({"ok": True, "commands": commands})


def async_register_views(hass: HomeAssistant) -> None:
    """Register the views once per HA run."""
    if hass.data.get(f"{DOMAIN}_views"):
        return
    hass.data[f"{DOMAIN}_views"] = True
    hass.http.register_view(BrickReportView())
    hass.http.register_view(BrickCommandsView())
