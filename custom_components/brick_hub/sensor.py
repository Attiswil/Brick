"""Brick Hub sensors: emergency allowance, timers and stats."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import UnitOfTime
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.util import dt as dt_util

from .entity import BrickEntity
from .hub import BrickHub


def _stats(hub: BrickHub) -> dict[str, Any]:
    return hub.engine.stats(dt_util.utcnow(), dt_util.get_default_time_zone())


@dataclass(frozen=True, kw_only=True)
class BrickSensorDescription(SensorEntityDescription):
    value: Callable[[BrickHub], Any]
    attrs: Callable[[BrickHub], dict[str, Any]] | None = None


SENSORS: tuple[BrickSensorDescription, ...] = (
    BrickSensorDescription(
        key="emergency_unbricks_remaining",
        icon="mdi:lifebuoy",
        state_class=SensorStateClass.MEASUREMENT,
        value=lambda h: h.engine.emergency_remaining,
        attrs=lambda h: {"max": h.engine.settings.emergency_max},
    ),
    BrickSensorDescription(
        key="emergency_reset_at",
        device_class=SensorDeviceClass.TIMESTAMP,
        icon="mdi:timer-sand",
        value=lambda h: h.engine.emergency_reset_at,
    ),
    BrickSensorDescription(
        key="bricked_since",
        device_class=SensorDeviceClass.TIMESTAMP,
        value=lambda h: h.engine.bricked_since,
    ),
    BrickSensorDescription(
        key="brick_ends_at",
        device_class=SensorDeviceClass.TIMESTAMP,
        icon="mdi:timer-outline",
        value=lambda h: h.engine.ends_at if h.engine.bricked else None,
    ),
    BrickSensorDescription(
        key="time_bricked_today",
        device_class=SensorDeviceClass.DURATION,
        native_unit_of_measurement=UnitOfTime.MINUTES,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=0,
        icon="mdi:clock-check-outline",
        value=lambda h: round(_stats(h)["today_seconds"] / 60, 1),
    ),
    BrickSensorDescription(
        key="time_bricked_week",
        device_class=SensorDeviceClass.DURATION,
        native_unit_of_measurement=UnitOfTime.HOURS,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        icon="mdi:calendar-week",
        value=lambda h: round(_stats(h)["week_seconds"] / 3600, 2),
    ),
    BrickSensorDescription(
        key="streak",
        icon="mdi:fire",
        native_unit_of_measurement="d",
        state_class=SensorStateClass.MEASUREMENT,
        value=lambda h: _stats(h)["streak_days"],
        attrs=lambda h: {
            "sessions_total": _stats(h)["sessions_total"],
            "longest_session_minutes": round(
                _stats(h)["longest_session_seconds"] / 60
            ),
        },
    ),
    BrickSensorDescription(
        key="last_method",
        icon="mdi:gesture-tap",
        value=lambda h: h.engine.last_method,
        attrs=lambda h: {"source": h.engine.source},
    ),
    BrickSensorDescription(
        key="brick_tags",
        icon="mdi:nfc-variant",
        value=lambda h: len(h.engine.tags),
        attrs=lambda h: {"tags": sorted(h.engine.tags.values())},
    ),
)


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    async_add_entities(BrickSensor(entry.runtime_data, d) for d in SENSORS)


class BrickSensor(BrickEntity, SensorEntity):
    """Generic description-driven sensor."""

    entity_description: BrickSensorDescription

    def __init__(self, hub: BrickHub, description: BrickSensorDescription) -> None:
        super().__init__(hub, description.key)
        self.entity_description = description

    @property
    def native_value(self) -> datetime | float | int | str | None:
        return self.entity_description.value(self.hub)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        if self.entity_description.attrs is None:
            return None
        return self.entity_description.attrs(self.hub)
