"""Bricked switch (per phone)."""

from __future__ import annotations

from typing import Any

from homeassistant.components.switch import SwitchEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import PhoneEntity, setup_phone_platform


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    setup_phone_platform(hass, entry, async_add_entities, lambda h, p: [BrickedSwitch(h, p)])


class BrickedSwitch(PhoneEntity, SwitchEntity):
    """Shows whether the phone is bricked; flipping it sends a command.

    The state only changes once the phone confirms - the phone decides
    (e.g. strict mode refuses a manual unbrick from the dashboard).
    """

    def __init__(self, hub, phone) -> None:
        super().__init__(hub, phone, "bricked")

    @property
    def is_on(self) -> bool:
        return self.phone.bricked

    @property
    def icon(self) -> str:
        return "mdi:cellphone-lock" if self.is_on else "mdi:cellphone"

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        p = self.phone
        return {
            "mode": p.mode_name,
            "source": p.state.get("source"),
            "method": p.state.get("last_method"),
            "strict": p.rules.get("strict"),
            "emergency_max": p.rules.get("emergency_max"),
            "reset_hours": p.rules.get("reset_hours"),
            "last_command": p.last_result,
        }

    async def async_turn_on(self, **kwargs: Any) -> None:
        await self.send("brick")

    async def async_turn_off(self, **kwargs: Any) -> None:
        await self.send("unbrick")
