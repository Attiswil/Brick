"""The main "Bricked" switch."""

from __future__ import annotations

from typing import Any

from homeassistant.components.switch import SwitchEntity
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
    async_add_entities([BrickedSwitch(entry.runtime_data)])


class BrickedSwitch(BrickEntity, SwitchEntity):
    """On = bricked. Turning it off by hand obeys strict mode."""

    def __init__(self, hub) -> None:
        super().__init__(hub, "bricked")

    @property
    def is_on(self) -> bool:
        return self.hub.engine.bricked

    @property
    def icon(self) -> str:
        return "mdi:cellphone-lock" if self.is_on else "mdi:cellphone"

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        eng = self.hub.engine
        return {
            "mode": eng.modes.get(eng.mode_id or ""),
            "mode_id": eng.mode_id,
            "source": eng.source,
            "method": eng.last_method,
            "strict": eng.settings.strict,
        }

    async def _run(self, action: Action) -> None:
        source = "Home Assistant" if self._context and self._context.user_id else "Automation"
        try:
            await self.hub.async_command(
                Command(action, method_from_context(self._context), source=source),
                context=self._context,
            )
        except BrickError as err:
            raise HomeAssistantError(err.message) from err

    async def async_turn_on(self, **kwargs: Any) -> None:
        await self._run(Action.BRICK)

    async def async_turn_off(self, **kwargs: Any) -> None:
        await self._run(Action.UNBRICK)
