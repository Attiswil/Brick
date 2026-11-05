"""Health of the connection to your iPhone(s)."""

from __future__ import annotations

from typing import Any

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import BrickEntity


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    hub = entry.runtime_data
    async_add_entities([PhoneInSync(hub), ScreenTimeProblem(hub)])


class PhoneInSync(BrickEntity, BinarySensorEntity):
    """On when every registered phone has applied the latest state."""

    _attr_icon = "mdi:cellphone-check"

    def __init__(self, hub) -> None:
        super().__init__(hub, "phone_in_sync")

    @property
    def is_on(self) -> bool | None:
        status = self.hub.device_sync_status()
        if not status:
            return None
        return all(d["in_sync"] for d in status.values())

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"devices": self.hub.device_sync_status()}


class ScreenTimeProblem(BrickEntity, BinarySensorEntity):
    """On (problem) if a phone has revoked Screen Time access.

    Revoking access is the one way to get around a brick on iOS, so this is
    worth an automation that nags you.
    """

    _attr_device_class = BinarySensorDeviceClass.PROBLEM

    def __init__(self, hub) -> None:
        super().__init__(hub, "screen_time_access")

    @property
    def is_on(self) -> bool | None:
        status = self.hub.device_sync_status()
        if not status:
            return None
        return any(not d["screen_time_authorized"] for d in status.values())
