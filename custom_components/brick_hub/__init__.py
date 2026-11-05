"""Brick Hub: let Home Assistant trigger the Brick Hub iPhone app.

The phone owns the brick (state, rules, emergency unbricks, tags) and works
without Home Assistant. This integration lets any HA trigger send it
commands and shows each phone's state as entities.
"""

from __future__ import annotations

import voluptuous as vol

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, ServiceCall
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers import device_registry as dr
from homeassistant.helpers.typing import ConfigType

from .api import async_register_views
from .const import (
    ATTR_DEVICE_ID,
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
from .hub import BrickHub, Phone

PLATFORMS = [
    Platform.BINARY_SENSOR,
    Platform.BUTTON,
    Platform.SELECT,
    Platform.SENSOR,
    Platform.SWITCH,
]

CONFIG_SCHEMA = cv.config_entry_only_config_schema(DOMAIN)

TARGET = {vol.Optional(ATTR_DEVICE_ID): vol.All(cv.ensure_list, [cv.string])}
BRICK_SCHEMA = vol.Schema(
    {
        **TARGET,
        vol.Optional(ATTR_MODE): cv.string,
        vol.Optional(ATTR_DURATION): cv.positive_time_period,
        vol.Optional(ATTR_SOURCE): cv.string,
    }
)
SIMPLE_SCHEMA = vol.Schema({**TARGET, vol.Optional(ATTR_SOURCE): cv.string})
ADD_TAG_SCHEMA = vol.Schema(
    {**TARGET, vol.Required(ATTR_TAG_ID): cv.string, vol.Optional(ATTR_NAME): cv.string}
)
REMOVE_TAG_SCHEMA = vol.Schema({**TARGET, vol.Required(ATTR_TAG_ID): cv.string})

type BrickConfigEntry = ConfigEntry[BrickHub]


def _hub(hass: HomeAssistant) -> BrickHub:
    hub = next(iter(hass.data.get(DOMAIN, {}).values()), None)
    if hub is None:
        raise ServiceValidationError("Brick Hub isn't set up")
    return hub


def _target_phones(hass: HomeAssistant, hub: BrickHub, call: ServiceCall) -> list[Phone]:
    """Map HA device ids to phones. No device given = every phone."""
    ha_ids = call.data.get(ATTR_DEVICE_ID)
    if not ha_ids:
        phones = hub.resolve_phones(None)
    else:
        registry = dr.async_get(hass)
        phone_ids = []
        for ha_id in ha_ids:
            device = registry.async_get(ha_id)
            ident = next(
                (i[1] for i in device.identifiers if i[0] == DOMAIN), None
            ) if device else ha_id  # also accept the phone's own id
            phone_ids.append(ident)
        phones = hub.resolve_phones(phone_ids)
    if not phones:
        raise ServiceValidationError(
            "No phones are linked yet. Open the Brick Hub app → Settings → Link Home Assistant."
        )
    return phones


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Register services."""

    def handler(action: str):
        async def handle(call: ServiceCall) -> None:
            hub = _hub(hass)
            await hub.async_send(
                _target_phones(hass, hub, call),
                action,
                context=call.context,
                mode=call.data.get(ATTR_MODE),
                duration=call.data.get(ATTR_DURATION),
                tag_id=call.data.get(ATTR_TAG_ID),
                tag_name=call.data.get(ATTR_NAME),
                source=call.data.get(ATTR_SOURCE),
            )

        return handle

    for service, action, schema in (
        (SERVICE_BRICK, "brick", BRICK_SCHEMA),
        (SERVICE_UNBRICK, "unbrick", SIMPLE_SCHEMA),
        (SERVICE_TOGGLE, "toggle", BRICK_SCHEMA),
        (SERVICE_EMERGENCY_UNBRICK, "emergency_unbrick", SIMPLE_SCHEMA),
        (SERVICE_REQUEST_RESET, "request_emergency_reset", SIMPLE_SCHEMA),
        (SERVICE_CANCEL_RESET, "cancel_emergency_reset", SIMPLE_SCHEMA),
        (SERVICE_ADD_TAG, "register_tag", ADD_TAG_SCHEMA),
        (SERVICE_REMOVE_TAG, "remove_tag", REMOVE_TAG_SCHEMA),
    ):
        hass.services.async_register(DOMAIN, service, handler(action), schema)
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


async def async_remove_config_entry_device(
    hass: HomeAssistant, entry: BrickConfigEntry, device: dr.DeviceEntry
) -> bool:
    """Let people delete an old phone from the UI."""
    hub = entry.runtime_data
    for ident in device.identifiers:
        if ident[0] == DOMAIN:
            hub.phones.pop(ident[1], None)
            hub.pending.pop(ident[1], None)
    await hub.async_save()
    return True
