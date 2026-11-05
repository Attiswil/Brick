"""Integration tests: HA as a remote control + mirror for phones."""

from __future__ import annotations

import asyncio
from datetime import timedelta
from unittest.mock import AsyncMock, patch

import pytest
from freezegun.api import FrozenDateTimeFactory
from homeassistant.core import Context, HomeAssistant
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import device_registry as dr
from homeassistant.setup import async_setup_component
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import (
    MockConfigEntry,
    async_capture_events,
    async_fire_time_changed,
)

from custom_components.brick_hub.apns import ApnsClient, PushResult
from custom_components.brick_hub.const import DOMAIN
from custom_components.brick_hub.tags import hash_tag

SWITCH = "switch.will_s_iphone_bricked"


@pytest.fixture(autouse=True)
async def auto_enable_custom_integrations(enable_custom_integrations):
    """Let HA load custom_components/brick_hub."""
    yield


@pytest.fixture
async def entry(hass: HomeAssistant) -> MockConfigEntry:
    assert await async_setup_component(hass, "http", {})
    entry = MockConfigEntry(domain=DOMAIN, unique_id=DOMAIN, data={})
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    return entry


def report(**state) -> dict:
    """What the iOS app sends (PhoneReport, snake_case)."""
    return {
        "device_id": "phone-1",
        "name": "Will's iPhone",
        "app_version": "0.2.0",
        "authorized": True,
        "modes": [{"id": "m1", "name": "Deep work"}, {"id": "m2", "name": "Bedtime"}],
        "tag_hashes": [hash_tag("04:AB:CD:EF")],
        "rules": {"strict": True, "emergency_max": 5, "reset_hours": 48,
                  "auto_request_reset": False, "tag_toggles": True},
        "state": {"revision": 1, "bricked": False, "emergency_remaining": 5, **state},
        "stats": {"today_seconds": 600, "week_seconds": 7200, "streak_days": 3,
                  "sessions_total": 9, "longest_session_seconds": 5400},
        "results": [],
    }


@pytest.fixture
async def client(hass: HomeAssistant, entry, hass_client):
    client = await hass_client()
    resp = await client.post("/api/brick_hub/report", json=report())
    assert (await resp.json()) == {"ok": True, "commands": []}
    await hass.async_block_till_done()
    return client


async def commands(client) -> list[dict]:
    resp = await client.get("/api/brick_hub/commands?device_id=phone-1")
    return (await resp.json())["commands"]


async def test_config_flow(hass: HomeAssistant) -> None:
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": "user"})
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    assert result["type"] == "create_entry"


async def test_phone_report_creates_mirror_entities(hass: HomeAssistant, client) -> None:
    assert hass.states.get(SWITCH).state == "off"
    assert hass.states.get("select.will_s_iphone_mode").state == "Deep work"
    assert hass.states.get("sensor.will_s_iphone_streak").state == "3"
    assert hass.states.get("sensor.will_s_iphone_emergency_unbricks_remaining").state == "5"
    assert hass.states.get("binary_sensor.will_s_iphone_screen_time_access").state == "off"
    now = dt_util.utcnow()
    await client.post("/api/brick_hub/report", json=report(
        revision=2, bricked=True, mode_id="m2", source="Brick tag", last_method="tag",
        bricked_since=(now - timedelta(minutes=5)).isoformat(),
    ))
    await hass.async_block_till_done()
    state = hass.states.get(SWITCH)
    assert state.state == "on"
    assert state.attributes["mode"] == "Bedtime"
    assert state.attributes["strict"] is True
    assert hass.states.get("select.will_s_iphone_mode").state == "Bedtime"


async def test_automation_sends_command_and_phone_reports_result(
    hass: HomeAssistant, client
) -> None:
    results = async_capture_events(hass, "brick_hub_command_result")
    await hass.services.async_call(
        DOMAIN, "brick", {"mode": "bedtime", "duration": {"minutes": 90}, "source": "Bedtime"},
        blocking=True, context=Context(),
    )
    [cmd] = await commands(client)
    assert cmd["action"] == "brick"
    assert cmd["method"] == "automation"
    assert cmd["mode_id"] == "m2"  # resolved by name, case-insensitively
    assert cmd["duration_minutes"] == 90
    assert cmd["source"] == "Bedtime"
    # HA doesn't pretend: the switch only flips when the phone says so.
    assert hass.states.get(SWITCH).state == "off"

    payload = report(revision=2, bricked=True, mode_id="m2")
    payload["results"] = [{"id": cmd["id"], "ok": True, "changed": True}]
    resp = await client.post("/api/brick_hub/report", json=payload)
    assert (await resp.json())["commands"] == []
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "on"
    assert results[-1].data["ok"] is True and results[-1].data["action"] == "brick"
    assert await commands(client) == []


async def test_dashboard_is_manual_and_refusal_is_reported(
    hass: HomeAssistant, client, hass_admin_user
) -> None:
    results = async_capture_events(hass, "brick_hub_command_result")
    await hass.services.async_call(
        "switch", "turn_off", {"entity_id": SWITCH},
        blocking=True, context=Context(user_id=hass_admin_user.id),
    )
    [cmd] = await commands(client)
    assert cmd["method"] == "manual"
    payload = report()
    payload["results"] = [{"id": cmd["id"], "ok": False, "code": "strict_mode",
                           "message": "Strict mode is on"}]
    await client.post("/api/brick_hub/report", json=payload)
    await hass.async_block_till_done()
    assert results[-1].data["code"] == "strict_mode"
    assert hass.states.get(SWITCH).attributes["last_command"]["code"] == "strict_mode"


async def test_undelivered_commands_are_dropped(
    hass: HomeAssistant, client, freezer: FrozenDateTimeFactory
) -> None:
    results = async_capture_events(hass, "brick_hub_command_result")
    await hass.services.async_call(DOMAIN, "brick", {}, blocking=True)
    assert len(await commands(client)) == 1
    freezer.tick(timedelta(seconds=121))
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert await commands(client) == []
    assert results[-1].data["code"] == "no_response"


async def test_long_poll_wakes_on_command(hass: HomeAssistant, client) -> None:
    task = asyncio.create_task(client.get("/api/brick_hub/commands?device_id=phone-1&wait=20"))
    await asyncio.sleep(0.2)
    assert not task.done()
    await hass.services.async_call(DOMAIN, "unbrick", {}, blocking=True)
    resp = await asyncio.wait_for(task, 5)
    [cmd] = (await resp.json())["commands"]
    assert cmd["action"] == "unbrick" and cmd["method"] == "automation"


async def test_tag_scan_forwarded_to_owning_phone(hass: HomeAssistant, client) -> None:
    hass.bus.async_fire("tag_scanned", {"tag_id": "nope"})
    await hass.async_block_till_done()
    assert await commands(client) == []
    hass.bus.async_fire("tag_scanned", {"tag_id": "04-ab-cd-ef"})  # ESPHome-style
    await hass.async_block_till_done()
    [cmd] = await commands(client)
    assert cmd["action"] == "toggle" and cmd["method"] == "tag"
    assert cmd["tag_id"] == "04-ab-cd-ef"


async def test_target_specific_phone(hass: HomeAssistant, client) -> None:
    second = report()
    second.update(device_id="phone-2", name="Partner's iPhone")
    await client.post("/api/brick_hub/report", json=second)
    device = dr.async_get(hass).async_get_device(identifiers={(DOMAIN, "phone-2")})
    await hass.services.async_call(
        DOMAIN, "brick", {"device_id": device.id}, blocking=True
    )
    assert await commands(client) == []
    resp = await client.get("/api/brick_hub/commands?device_id=phone-2")
    assert len((await resp.json())["commands"]) == 1


async def test_mirror_derives_timer_and_reset(
    hass: HomeAssistant, client, freezer: FrozenDateTimeFactory
) -> None:
    now = dt_util.utcnow()
    await client.post("/api/brick_hub/report", json=report(
        revision=3, bricked=True, bricked_since=now.isoformat(),
        ends_at=(now + timedelta(minutes=10)).isoformat(),
        emergency_remaining=0, emergency_reset_at=(now + timedelta(minutes=20)).isoformat(),
    ))
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "on"
    # The phone's own timer ends the brick even if it can't report in time.
    freezer.tick(timedelta(minutes=10, seconds=1))
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "off"
    freezer.tick(timedelta(minutes=10))
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert hass.states.get("sensor.will_s_iphone_emergency_unbricks_remaining").state == "5"


async def test_select_sets_mode_for_ha_bricks(hass: HomeAssistant, client) -> None:
    await hass.services.async_call(
        "select", "select_option",
        {"entity_id": "select.will_s_iphone_mode", "option": "Bedtime"}, blocking=True,
    )
    assert hass.states.get("select.will_s_iphone_mode").state == "Bedtime"
    await hass.services.async_call(DOMAIN, "brick", {}, blocking=True)
    [cmd] = await commands(client)
    assert cmd["mode_id"] == "m2"


async def test_no_phones_is_a_clear_error(hass: HomeAssistant, entry) -> None:
    with pytest.raises(ServiceValidationError, match="No phones are linked"):
        await hass.services.async_call(DOMAIN, "brick", {}, blocking=True)


async def test_push_carries_command_and_expiry(hass: HomeAssistant, entry, client) -> None:
    hub = entry.runtime_data
    hub.apns = ApnsClient(hass, "TEAM", "KEY", "unused", "com.example.brickhub")
    with_token = report()
    with_token.update(apns_token="tok", apns_sandbox=True)
    await client.post("/api/brick_hub/report", json=with_token)
    send = AsyncMock(return_value=PushResult(200))
    with patch.object(hub.apns, "send", send):
        await hass.services.async_call(DOMAIN, "brick", {"mode": "Deep work"}, blocking=True)
        await hass.async_block_till_done()
    payload = send.call_args.args[1]
    assert payload["brick_cmd"]["mode_id"] == "m1"
    assert payload["aps"]["mutable-content"] == 1
    assert send.call_args.kwargs["sandbox"] is True
    expires = send.call_args.kwargs["expires_at"]
    assert 115 <= expires - dt_util.utcnow().timestamp() <= 121


async def test_phones_persist(hass: HomeAssistant, entry, client) -> None:
    assert await hass.config_entries.async_reload(entry.entry_id)
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH) is not None
    assert hass.states.get("select.will_s_iphone_mode").state == "Deep work"


async def test_tag_hash_matches_ios() -> None:
    # Same value asserted in ios/BrickCore/Tests (TagHash.swift).
    assert hash_tag("04:a1:b2:c3") == (
        "27e80505ce6eaff0769f20aff4531f6758247ca9c2b3821e73caf386695bcc8b"
    )
