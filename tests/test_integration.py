"""Integration tests: services, entities, tags, timers and the phone API."""

from __future__ import annotations

import asyncio
from datetime import timedelta

import pytest
from freezegun.api import FrozenDateTimeFactory
from homeassistant.core import Context, HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.setup import async_setup_component
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import (
    MockConfigEntry,
    async_fire_time_changed,
)

from custom_components.brick_hub.const import DOMAIN

SWITCH = "switch.brick_hub_bricked"
REMAINING = "sensor.brick_hub_emergency_unbricks_remaining"


@pytest.fixture(autouse=True)
async def auto_enable_custom_integrations(enable_custom_integrations):
    """Let HA load custom_components/brick_hub."""
    yield


@pytest.fixture
async def entry(hass: HomeAssistant) -> MockConfigEntry:
    assert await async_setup_component(hass, "http", {})
    entry = MockConfigEntry(
        domain=DOMAIN,
        unique_id=DOMAIN,
        data={"emergency_max": 2, "reset_hours": 48, "strict": True},
    )
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    return entry


async def test_config_flow(hass: HomeAssistant) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": "user"})
    assert result["type"] == "form"
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"],
        {"emergency_max": 5, "reset_hours": 48, "strict": True,
         "auto_request_reset": False, "tag_toggles": True},
    )
    assert result["type"] == "create_entry"
    assert result["data"]["emergency_max"] == 5


async def test_automation_bricks_and_strict_blocks_manual(
    hass: HomeAssistant, entry, hass_admin_user
) -> None:
    # No user on the context = automation.
    await hass.services.async_call(
        DOMAIN, "brick", {"source": "Bedtime", "duration": {"minutes": 30}},
        blocking=True, context=Context(),
    )
    state = hass.states.get(SWITCH)
    assert state.state == "on"
    assert state.attributes["source"] == "Bedtime"

    # A person flipping the switch in strict mode is refused.
    with pytest.raises(HomeAssistantError, match="Strict mode"):
        await hass.services.async_call(
            "switch", "turn_off", {"entity_id": SWITCH},
            blocking=True, context=Context(user_id=hass_admin_user.id),
        )
    assert hass.states.get(SWITCH).state == "on"

    # Options are locked while bricked.
    result = await hass.config_entries.options.async_init(entry.entry_id)
    assert result["type"] == "abort"
    assert result["reason"] == "locked_while_bricked"

    # An automation may unbrick.
    await hass.services.async_call(DOMAIN, "unbrick", {}, blocking=True, context=Context())
    assert hass.states.get(SWITCH).state == "off"


async def test_timer_unbricks(
    hass: HomeAssistant, entry, freezer: FrozenDateTimeFactory
) -> None:
    await hass.services.async_call(
        DOMAIN, "brick", {"duration": {"minutes": 10}}, blocking=True
    )
    assert hass.states.get(SWITCH).state == "on"
    freezer.tick(timedelta(minutes=10, seconds=1))
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "off"
    assert hass.states.get("sensor.brick_hub_last_change_by").state == "timer"


async def test_tag_scanned_toggles(hass: HomeAssistant, entry) -> None:
    await hass.services.async_call(
        DOMAIN, "add_tag", {"tag_id": "04:AB:CD:EF", "name": "Desk"}, blocking=True
    )
    hass.bus.async_fire("tag_scanned", {"tag_id": "04-ab-cd-ef"})
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "on"
    hass.bus.async_fire("tag_scanned", {"tag_id": "nope"})
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "on"
    hass.bus.async_fire("tag_scanned", {"tag_id": "04ABCDEF"})
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "off"


async def test_emergency_and_two_day_reset(
    hass: HomeAssistant, entry, freezer: FrozenDateTimeFactory
) -> None:
    for _ in range(2):
        await hass.services.async_call(DOMAIN, "brick", {}, blocking=True)
        await hass.services.async_call(
            "button", "press",
            {"entity_id": "button.brick_hub_emergency_unbrick"}, blocking=True,
        )
        assert hass.states.get(SWITCH).state == "off"
    assert hass.states.get(REMAINING).state == "0"

    await hass.services.async_call(DOMAIN, "brick", {}, blocking=True)
    with pytest.raises(HomeAssistantError, match="No emergency unbricks left"):
        await hass.services.async_call(DOMAIN, "emergency_unbrick", {}, blocking=True)
    await hass.services.async_call(DOMAIN, "request_emergency_reset", {}, blocking=True)
    reset_at = dt_util.parse_datetime(
        hass.states.get("sensor.brick_hub_emergency_reset_completes").state
    )
    assert abs(reset_at - dt_util.utcnow() - timedelta(hours=48)) < timedelta(seconds=5)

    freezer.tick(timedelta(hours=47))
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert hass.states.get(REMAINING).state == "0"
    freezer.tick(timedelta(hours=1, seconds=1))
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert hass.states.get(REMAINING).state == "2"


async def test_phone_api(hass: HomeAssistant, entry, hass_client) -> None:
    client = await hass_client()
    resp = await client.post(
        "/api/brick_hub/device",
        json={
            "device_id": "iphone-1", "name": "Will's iPhone",
            "modes": [{"id": "m1", "name": "Deep work"}, {"id": "m2", "name": "Bedtime"}],
            "authorized": True, "applied_revision": 0,
        },
    )
    body = await resp.json()
    assert body["ok"] and len(body["state"]["modes"]) == 2
    assert hass.states.get("select.brick_hub_mode").state == "Deep work"

    # HA brick by mode *name*.
    await hass.services.async_call(DOMAIN, "brick", {"mode": "Bedtime"}, blocking=True)
    resp = await client.get("/api/brick_hub/state")
    state = (await resp.json())["state"]
    assert state["bricked"] and state["mode_id"] == "m2"
    assert hass.states.get("binary_sensor.brick_hub_phone_in_sync").state == "off"

    # Phone acks the revision.
    await client.post(
        "/api/brick_hub/device",
        json={"device_id": "iphone-1", "applied_revision": state["revision"]},
    )
    assert hass.states.get("binary_sensor.brick_hub_phone_in_sync").state == "on"

    # A phone claiming "automation" is downgraded to manual -> strict refuses.
    resp = await client.post(
        "/api/brick_hub/command",
        json={"action": "unbrick", "method": "automation", "device_id": "iphone-1"},
    )
    assert resp.status == 409
    assert (await resp.json())["code"] == "strict_mode"

    # A phone claiming "timer" before the timer ends is also manual.
    resp = await client.post(
        "/api/brick_hub/command",
        json={"action": "unbrick", "method": "timer", "device_id": "iphone-1"},
    )
    assert resp.status == 409

    # Emergency from the phone, deduplicated by event id.
    for _ in range(2):
        resp = await client.post(
            "/api/brick_hub/command",
            json={"action": "emergency_unbrick", "event_id": "e1", "device_id": "iphone-1"},
        )
        assert resp.status == 200
    state = (await resp.json())["state"]
    assert not state["bricked"] and state["emergency_remaining"] == 1


async def test_long_poll_wakes(hass: HomeAssistant, entry, hass_client) -> None:
    client = await hass_client()
    rev = (await (await client.get("/api/brick_hub/state")).json())["state"]["revision"]
    task = asyncio.create_task(client.get(f"/api/brick_hub/state?since={rev}&wait=20"))
    await asyncio.sleep(0.2)
    assert not task.done()
    await hass.services.async_call(DOMAIN, "brick", {}, blocking=True)
    resp = await task
    assert (await resp.json())["state"]["revision"] == rev + 1


async def test_state_persists(hass: HomeAssistant, entry) -> None:
    await hass.services.async_call(DOMAIN, "brick", {}, blocking=True)
    assert await hass.config_entries.async_reload(entry.entry_id)
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "on"


async def test_push_sent_to_other_devices(hass: HomeAssistant, entry, hass_client) -> None:
    from unittest.mock import AsyncMock, patch

    from custom_components.brick_hub.apns import ApnsClient, PushResult

    hub = entry.runtime_data
    hub.apns = ApnsClient(hass, "TEAM", "KEY", "unused", "com.example.brickhub")
    client = await hass_client()
    for dev, token in (("a", "tok-a"), ("b", "tok-b")):
        await client.post(
            "/api/brick_hub/device",
            json={"device_id": dev, "apns_token": token, "apns_sandbox": True},
        )
    send = AsyncMock(
        side_effect=lambda token, payload, **kw: PushResult(
            410 if token == "tok-b" else 200, "Unregistered" if token == "tok-b" else None
        )
    )
    with patch.object(hub.apns, "send", send):
        # Phone "a" bricks itself: only "b" should be pushed.
        await client.post(
            "/api/brick_hub/command", json={"action": "brick", "device_id": "a"}
        )
        await hass.async_block_till_done()
    assert [c.args[0] for c in send.call_args_list] == ["tok-b"]
    payload = send.call_args.args[1]
    assert payload["brick"]["bricked"] is True
    assert payload["aps"]["mutable-content"] == 1
    assert send.call_args.kwargs["sandbox"] is True
    # Dead token is dropped.
    assert "apns_token" not in hub.devices["b"]
