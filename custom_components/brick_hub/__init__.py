"""Brick Hub: an NFC-style app blocker for iPhone, driven by Home Assistant.

Any Home Assistant trigger can brick or unbrick your phone. The companion
iOS app applies the block with Apple's Screen Time API.
"""

from __future__ import annotations

import voluptuous as vol

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, ServiceCall
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.typing import ConfigType

from .api import async_register_views
from .const import (
    ATTR_DURATION,
    ATTR_MODE,
    ATTR_NAME,
    ATTR_SOURCE,
    ATTR_TAG_ID,
    DOMAIN,
    SERVICE_ADD_TAG,
    SERVICE_BRICK,
    SERVICE_CANCEL_RESET,
    SERVICE_EMERGENCY_UNBRICK,
    SERVICE_REMOVE_TAG,
    SERVICE_REQUEST_RESET,
    SERVICE_TOGGLE,
    SERVICE_UNBRICK,
)
from .engine import Action, BrickError, Command, Method
from .hub import BrickHub, method_from_context

PLATFORMS = [
    Platform.BINARY_SENSOR,
    Platform.BUTTON,
    Platform.SELECT,
    Platform.SENSOR,
    Platform.SWITCH,
]

CONFIG_SCHEMA = cv.config_entry_only_config_schema(DOMAIN)

BRICK_SCHEMA = vol.Schema(
    {
        vol.Optional(ATTR_MODE): cv.string,
        vol.Optional(ATTR_DURATION): cv.positive_time_period,
        vol.Optional(ATTR_SOURCE): cv.string,
    }
)
UNBRICK_SCHEMA = vol.Schema({vol.Optional(ATTR_SOURCE): cv.string})
EMPTY_SCHEMA = vol.Schema({})
ADD_TAG_SCHEMA = vol.Schema(
    {vol.Required(ATTR_TAG_ID): cv.string, vol.Optional(ATTR_NAME): cv.string}
)
REMOVE_TAG_SCHEMA = vol.Schema({vol.Required(ATTR_TAG_ID): cv.string})

type BrickConfigEntry = ConfigEntry[BrickHub]


def get_hub(hass: HomeAssistant) -> BrickHub:
    hubs: dict[str, BrickHub] = hass.data.get(DOMAIN, {})
    hub = next(iter(hubs.values()), None)
    if hub is None:
        raise ServiceValidationError("Brick Hub isn't set up")
    return hub


async def async_run(hub: BrickHub, cmd: Command, call_context) -> None:
    """Run a command, turning refusals into readable HA errors."""
    try:
        await hub.async_command(cmd, context=call_context)
    except BrickError as err:
        raise HomeAssistantError(err.message) from err


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Register services (once, independent of config entries)."""

    def _source(call: ServiceCall) -> str:
        if call.data.get(ATTR_SOURCE):
            return call.data[ATTR_SOURCE]
        return "Home Assistant" if call.context.user_id else "Automation"

    async def brick(call: ServiceCall) -> None:
        hub = get_hub(hass)
        await async_run(
            hub,
            Command(
                Action.BRICK,
                method_from_context(call.context),
                mode_id=hub.resolve_mode(call.data.get(ATTR_MODE)),
                duration=call.data.get(ATTR_DURATION),
                source=_source(call),
            ),
            call.context,
        )

    async def unbrick(call: ServiceCall) -> None:
        hub = get_hub(hass)
        await async_run(
            hub,
            Command(
                Action.UNBRICK,
                method_from_context(call.context),
                source=_source(call),
            ),
            call.context,
        )

    async def toggle(call: ServiceCall) -> None:
        hub = get_hub(hass)
        await async_run(
            hub,
            Command(
                Action.TOGGLE,
                method_from_context(call.context),
                mode_id=hub.resolve_mode(call.data.get(ATTR_MODE)),
                duration=call.data.get(ATTR_DURATION),
                source=_source(call),
            ),
            call.context,
        )

    def simple(action: Action):
        async def handler(call: ServiceCall) -> None:
            hub = get_hub(hass)
            await async_run(
                hub,
                Command(action, method_from_context(call.context), source=_source(call)),
                call.context,
            )

        return handler

    async def add_tag(call: ServiceCall) -> None:
        hub = get_hub(hass)
        await async_run(
            hub,
            Command(
                Action.REGISTER_TAG,
                Method.MANUAL,
                tag_id=call.data[ATTR_TAG_ID],
                tag_name=call.data.get(ATTR_NAME),
            ),
            call.context,
        )

    async def remove_tag(call: ServiceCall) -> None:
        hub = get_hub(hass)
        await async_run(
            hub,
            Command(Action.REMOVE_TAG, Method.MANUAL, tag_id=call.data[ATTR_TAG_ID]),
            call.context,
        )

    hass.services.async_register(DOMAIN, SERVICE_BRICK, brick, BRICK_SCHEMA)
    hass.services.async_register(DOMAIN, SERVICE_UNBRICK, unbrick, UNBRICK_SCHEMA)
    hass.services.async_register(DOMAIN, SERVICE_TOGGLE, toggle, BRICK_SCHEMA)
    hass.services.async_register(
        DOMAIN,
        SERVICE_EMERGENCY_UNBRICK,
        simple(Action.EMERGENCY_UNBRICK),
        EMPTY_SCHEMA,
    )
    hass.services.async_register(
        DOMAIN, SERVICE_REQUEST_RESET, simple(Action.REQUEST_RESET), EMPTY_SCHEMA
    )
    hass.services.async_register(
        DOMAIN, SERVICE_CANCEL_RESET, simple(Action.CANCEL_RESET), EMPTY_SCHEMA
    )
    hass.services.async_register(DOMAIN, SERVICE_ADD_TAG, add_tag, ADD_TAG_SCHEMA)
    hass.services.async_register(
        DOMAIN, SERVICE_REMOVE_TAG, remove_tag, REMOVE_TAG_SCHEMA
    )
    return True


async def async_setup_entry(hass: HomeAssistant, entry: BrickConfigEntry) -> bool:
    """Set up Brick Hub from a config entry."""
    hub = BrickHub(hass, entry)
    await hub.async_setup()
    entry.runtime_data = hub
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = hub
    async_register_views(hass)
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    entry.async_on_unload(entry.add_update_listener(_async_reload))
    return True


async def _async_reload(hass: HomeAssistant, entry: BrickConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: BrickConfigEntry) -> bool:
    """Unload a config entry."""
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded:
        hub: BrickHub = hass.data[DOMAIN].pop(entry.entry_id)
        await hub.async_unload()
    return unloaded
