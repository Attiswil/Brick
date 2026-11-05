"""Screen Time access problem sensor (per phone)."""

from __future__ import annotations

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import PhoneEntity, setup_phone_platform


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    setup_phone_platform(hass, entry, async_add_entities, lambda h, p: [ScreenTimeProblem(h, p)])


class ScreenTimeProblem(PhoneEntity, BinarySensorEntity):
    """On (problem) when the phone has lost Screen Time access - the one
    way around a brick on iOS. Worth an automation that nags you."""

    _attr_device_class = BinarySensorDeviceClass.PROBLEM

    def __init__(self, hub, phone) -> None:
        super().__init__(hub, phone, "screen_time_access")

    @property
    def is_on(self) -> bool:
        return not self.phone.authorized
