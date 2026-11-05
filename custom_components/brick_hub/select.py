"""Mode select (per phone). Modes are created in the iPhone app."""

from __future__ import annotations

from homeassistant.components.select import SelectEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import PhoneEntity, setup_phone_platform


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    setup_phone_platform(hass, entry, async_add_entities, lambda h, p: [ModeSelect(h, p)])


class ModeSelect(PhoneEntity, SelectEntity):
    """Unbricked: the mode HA uses when an automation doesn't name one.
    Bricked: the active mode; choosing another asks the phone to switch."""

    _attr_icon = "mdi:format-list-checks"

    def __init__(self, hub, phone) -> None:
        super().__init__(hub, phone, "mode")

    @property
    def options(self) -> list[str]:
        return list(self.phone.modes.values())

    @property
    def available(self) -> bool:
        return bool(self.phone.modes)

    @property
    def current_option(self) -> str | None:
        p = self.phone
        if p.bricked:
            return p.mode_name
        return p.modes.get(p.ha_mode or "")

    async def async_select_option(self, option: str) -> None:
        mode_id = next((k for k, v in self.phone.modes.items() if v == option), None)
        if self.phone.bricked:
            await self.send("brick", mode=mode_id)
        else:
            await self.hub.async_set_ha_mode(self.phone, mode_id)
