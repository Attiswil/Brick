"""Sensors mirroring each phone."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory, UnitOfTime
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import PhoneEntity, setup_phone_platform
from .hub import Phone, parse_dt


@dataclass(frozen=True, kw_only=True)
class PhoneSensorDescription(SensorEntityDescription):
    value: Callable[[Phone], Any]
    attrs: Callable[[Phone], dict[str, Any]] | None = None


SENSORS: tuple[PhoneSensorDescription, ...] = (
    PhoneSensorDescription(
        key="emergency_unbricks_remaining",
        icon="mdi:lifebuoy",
        state_class=SensorStateClass.MEASUREMENT,
        value=lambda p: p.emergency_remaining,
        attrs=lambda p: {"max": p.rules.get("emergency_max")},
    ),
    PhoneSensorDescription(
        key="emergency_reset_at",
        device_class=SensorDeviceClass.TIMESTAMP,
        icon="mdi:timer-sand",
        value=lambda p: p.emergency_reset_at,
    ),
    PhoneSensorDescription(
        key="bricked_since",
        device_class=SensorDeviceClass.TIMESTAMP,
        value=lambda p: p.bricked_since,
    ),
    PhoneSensorDescription(
        key="brick_ends_at",
        device_class=SensorDeviceClass.TIMESTAMP,
        icon="mdi:timer-outline",
        value=lambda p: p.ends_at if p.bricked else None,
    ),
    PhoneSensorDescription(
        key="time_bricked_today",
        device_class=SensorDeviceClass.DURATION,
        native_unit_of_measurement=UnitOfTime.MINUTES,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=0,
        icon="mdi:clock-check-outline",
        value=lambda p: round(p.today_seconds() / 60, 1),
    ),
    PhoneSensorDescription(
        key="time_bricked_week",
        device_class=SensorDeviceClass.DURATION,
        native_unit_of_measurement=UnitOfTime.HOURS,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        icon="mdi:calendar-week",
        value=lambda p: round(int(p.stats.get("week_seconds", 0)) / 3600, 2),
    ),
    PhoneSensorDescription(
        key="streak",
        icon="mdi:fire",
        native_unit_of_measurement="d",
        state_class=SensorStateClass.MEASUREMENT,
        value=lambda p: p.stats.get("streak_days"),
        attrs=lambda p: {
            "sessions_total": p.stats.get("sessions_total"),
            "longest_session_minutes": round(int(p.stats.get("longest_session_seconds", 0)) / 60),
        },
    ),
    PhoneSensorDescription(
        key="last_method",
        icon="mdi:gesture-tap",
        value=lambda p: p.state.get("last_method"),
        attrs=lambda p: {"source": p.state.get("source")},
    ),
    PhoneSensorDescription(
        key="last_report",
        device_class=SensorDeviceClass.TIMESTAMP,
        entity_category=EntityCategory.DIAGNOSTIC,
        icon="mdi:cellphone-arrow-down",
        value=lambda p: p.last_report,
        attrs=lambda p: {"state_changed": parse_dt(p.state.get("last_changed"))},
    ),
)


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    setup_phone_platform(
        hass, entry, async_add_entities,
        lambda h, p: [PhoneSensor(h, p, d) for d in SENSORS],
    )


class PhoneSensor(PhoneEntity, SensorEntity):
    """Description-driven sensor."""

    entity_description: PhoneSensorDescription

    def __init__(self, hub, phone: Phone, description: PhoneSensorDescription) -> None:
        super().__init__(hub, phone, description.key)
        self.entity_description = description

    @property
    def native_value(self) -> Any:
        return self.entity_description.value(self.phone)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        if self.entity_description.attrs is None:
            return None
        return self.entity_description.attrs(self.phone)
