"""Emergency unbrick and the 48h reset."""

from __future__ import annotations

from homeassistant.components.button import ButtonEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .engine import Action, BrickError, Command
from .entity import BrickEntity
from .hub import method_from_context

BUTTONS = {
    "emergency_unbrick": (Action.EMERGENCY_UNBRICK, "mdi:lifebuoy"),
    "request_emergency_reset": (Action.REQUEST_RESET, "mdi:timer-sand"),
    "cancel_emergency_reset": (Action.CANCEL_RESET, "mdi:timer-sand-paused"),
}


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    async_add_entities(
        BrickButton(entry.runtime_data, key, action, icon)
        for key, (action, icon) in BUTTONS.items()
    )


class BrickButton(BrickEntity, ButtonEntity):
    """A one-shot command."""

    def __init__(self, hub, key: str, action: Action, icon: str) -> None:
        super().__init__(hub, key)
        self._action = action
        self._attr_icon = icon

    async def async_press(self) -> None:
        try:
            await self.hub.async_command(
                Command(
                    self._action,
                    method_from_context(self._context),
                    source="Home Assistant",
                ),
                context=self._context,
            )
        except BrickError as err:
            raise HomeAssistantError(err.message) from err
