"""Base entity: one HA device per linked phone."""

from __future__ import annotations

from collections.abc import Callable, Iterable

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity import Entity
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN, SIGNAL_NEW_PHONE, SIGNAL_UPDATE
from .hub import BrickHub, Phone


def setup_phone_platform(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
    factory: Callable[[BrickHub, Phone], Iterable[Entity]],
) -> None:
    """Add entities for known phones now, and for new phones as they link."""
    hub: BrickHub = entry.runtime_data
    async_add_entities(e for phone in hub.phones.values() for e in factory(hub, phone))

    @callback
    def _new_phone(phone: Phone) -> None:
        async_add_entities(factory(hub, phone))

    entry.async_on_unload(async_dispatcher_connect(hass, SIGNAL_NEW_PHONE, _new_phone))


class PhoneEntity(Entity):
    """Mirrors one phone. State comes from the phone's own reports."""

    _attr_has_entity_name = True
    _attr_should_poll = False

    def __init__(self, hub: BrickHub, phone: Phone, key: str) -> None:
        self.hub = hub
        self.phone = phone
        self._attr_translation_key = key
        self._attr_unique_id = f"{phone.device_id}_{key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, phone.device_id)},
            name=phone.name,
            manufacturer="Brick Hub",
            model="iPhone",
            sw_version=phone.app_version or None,
        )

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(
            async_dispatcher_connect(self.hass, SIGNAL_UPDATE, self.async_write_ha_state)
        )

    async def send(self, action: str, **kwargs) -> None:
        """Send a command to this phone."""
        if action == "brick" and not self.phone.modes and kwargs.get("mode"):
            raise HomeAssistantError("This phone hasn't reported any modes yet")
        await self.hub.async_send([self.phone], action, context=self._context, **kwargs)
