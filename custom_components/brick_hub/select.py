"""Mode picker. Modes are defined in the iPhone app and synced here."""

from __future__ import annotations

from homeassistant.components.select import SelectEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .engine import Action, BrickError, Command
from .entity import BrickEntity
from .hub import method_from_context


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    async_add_entities([ModeSelect(entry.runtime_data)])


class ModeSelect(BrickEntity, SelectEntity):
    """While unbricked: the default mode. While bricked: the active mode."""

    _attr_icon = "mdi:format-list-checks"

    def __init__(self, hub) -> None:
        super().__init__(hub, "mode")

    @property
    def options(self) -> list[str]:
        return list(self.hub.engine.modes.values())

    @property
    def available(self) -> bool:
        return bool(self.hub.engine.modes)

    @property
    def current_option(self) -> str | None:
        eng = self.hub.engine
        mode_id = eng.mode_id if eng.bricked else eng.default_mode_id
        return eng.modes.get(mode_id or "")

    async def async_select_option(self, option: str) -> None:
        mode_id = self.hub.resolve_mode(option)
        if not self.hub.engine.bricked:
            await self.hub.async_set_default_mode(mode_id)
            return
        try:
            await self.hub.async_command(
                Command(
                    Action.BRICK,
                    method_from_context(self._context),
                    mode_id=mode_id,
                    source="Home Assistant",
                ),
                context=self._context,
            )
        except BrickError as err:
            raise HomeAssistantError(err.message) from err
