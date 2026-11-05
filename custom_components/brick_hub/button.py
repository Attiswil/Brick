"""Emergency unbrick and the reset (per phone)."""

from __future__ import annotations

from homeassistant.components.button import ButtonEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import PhoneEntity, setup_phone_platform

BUTTONS = {
    "emergency_unbrick": "mdi:lifebuoy",
    "request_emergency_reset": "mdi:timer-sand",
    "cancel_emergency_reset": "mdi:timer-sand-paused",
}


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    setup_phone_platform(
        hass, entry, async_add_entities,
        lambda h, p: [PhoneButton(h, p, key, icon) for key, icon in BUTTONS.items()],
    )


class PhoneButton(PhoneEntity, ButtonEntity):
    """Sends one command to the phone."""

    def __init__(self, hub, phone, key: str, icon: str) -> None:
        super().__init__(hub, phone, key)
        self._action = key
        self._attr_icon = icon

    async def async_press(self) -> None:
        await self.send(self._action)
