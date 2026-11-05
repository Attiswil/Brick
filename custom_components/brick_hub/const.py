"""Constants for Brick Hub."""

from __future__ import annotations

from typing import Final

DOMAIN: Final = "brick_hub"
NAME: Final = "Brick Hub"
STORAGE_VERSION: Final = 1

CONF_EMERGENCY_MAX: Final = "emergency_max"
CONF_RESET_HOURS: Final = "reset_hours"
CONF_STRICT: Final = "strict"
CONF_AUTO_RESET: Final = "auto_request_reset"
CONF_TAG_TOGGLES: Final = "tag_toggles"
CONF_PUSH_STYLE: Final = "push_style"
CONF_APNS_TEAM_ID: Final = "apns_team_id"
CONF_APNS_KEY_ID: Final = "apns_key_id"
CONF_APNS_KEY: Final = "apns_key"
CONF_APNS_BUNDLE_ID: Final = "apns_bundle_id"

DEFAULT_EMERGENCY_MAX: Final = 5
DEFAULT_RESET_HOURS: Final = 48
DEFAULT_STRICT: Final = True
DEFAULT_AUTO_RESET: Final = False
DEFAULT_TAG_TOGGLES: Final = True
DEFAULT_BUNDLE_ID: Final = "com.example.brickhub"

PUSH_ALERT: Final = "alert"  # visible banner; most reliable wake-up
PUSH_SILENT: Final = "silent"  # background push; iOS may delay/throttle
PUSH_OFF: Final = "off"
PUSH_STYLES: Final = [PUSH_ALERT, PUSH_SILENT, PUSH_OFF]

SIGNAL_UPDATE: Final = f"{DOMAIN}_update"
EVENT_STATE_CHANGED: Final = f"{DOMAIN}_state_changed"
EVENT_COMMAND_REFUSED: Final = f"{DOMAIN}_command_refused"

API_BASE: Final = "/api/brick_hub"
LONG_POLL_MAX_SECONDS: Final = 55

SERVICE_BRICK: Final = "brick"
SERVICE_UNBRICK: Final = "unbrick"
SERVICE_TOGGLE: Final = "toggle"
SERVICE_EMERGENCY_UNBRICK: Final = "emergency_unbrick"
SERVICE_REQUEST_RESET: Final = "request_emergency_reset"
SERVICE_CANCEL_RESET: Final = "cancel_emergency_reset"
SERVICE_ADD_TAG: Final = "add_tag"
SERVICE_REMOVE_TAG: Final = "remove_tag"

ATTR_MODE: Final = "mode"
ATTR_DURATION: Final = "duration"
ATTR_SOURCE: Final = "source"
ATTR_TAG_ID: Final = "tag_id"
ATTR_NAME: Final = "name"
