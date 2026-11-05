"""Unit tests for the pure Brick Hub engine (no Home Assistant needed)."""

from __future__ import annotations

import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

_PATH = Path(__file__).parents[1] / "custom_components" / "brick_hub" / "engine.py"
_spec = importlib.util.spec_from_file_location("brick_engine", _PATH)
engine = importlib.util.module_from_spec(_spec)
sys.modules["brick_engine"] = engine
_spec.loader.exec_module(engine)

Action, Command, Engine, Method, Settings, BrickError = (
    engine.Action, engine.Command, engine.Engine, engine.Method,
    engine.Settings, engine.BrickError,
)

T0 = datetime(2026, 11, 5, 9, 0, tzinfo=timezone.utc)
SYD = ZoneInfo("Australia/Sydney")


def make(**kw) -> Engine:
    return Engine.new(Settings(**kw))


def brick(e, at=T0, **kw):
    return e.handle(Command(Action.BRICK, Method.AUTOMATION, **kw), at)


def test_brick_and_tag_unbrick():
    e = make()
    e.handle(Command(Action.REGISTER_TAG, tag_id="04:A1:B2:C3", tag_name="Desk"), T0)
    brick(e, mode_id="focus")
    assert e.bricked and e.mode_id == "focus" and e.revision == 2
    with pytest.raises(BrickError) as err:
        e.handle(Command(Action.UNBRICK, Method.TAG, tag_id="FF-FF"), T0)
    assert err.value.code == engine.ERR_UNKNOWN_TAG
    # Different formatting of the same UID still matches.
    e.handle(Command(Action.UNBRICK, Method.TAG, tag_id="04-a1-b2-c3"), T0 + timedelta(hours=1))
    assert not e.bricked
    assert e.sessions[-1].ended_by == "tag"


def test_strict_blocks_manual_unbrick_but_not_automation():
    e = make(strict=True)
    brick(e)
    with pytest.raises(BrickError) as err:
        e.handle(Command(Action.UNBRICK, Method.MANUAL), T0)
    assert err.value.code == engine.ERR_STRICT
    e.handle(Command(Action.UNBRICK, Method.AUTOMATION), T0)
    assert not e.bricked


def test_non_strict_allows_manual():
    e = make(strict=False)
    brick(e)
    e.handle(Command(Action.UNBRICK, Method.MANUAL), T0)
    assert not e.bricked


def test_toggle():
    e = make(strict=False)
    e.handle(Command(Action.TOGGLE, Method.MANUAL), T0)
    assert e.bricked
    e.handle(Command(Action.TOGGLE, Method.MANUAL), T0)
    assert not e.bricked


def test_timer_and_no_shortening():
    e = make()
    brick(e, duration=timedelta(minutes=60))
    assert e.ends_at == T0 + timedelta(minutes=60)
    # Re-bricking with a shorter duration can't shorten it.
    brick(e, at=T0 + timedelta(minutes=1), duration=timedelta(minutes=5))
    assert e.ends_at == T0 + timedelta(minutes=60)
    # Longer extends.
    brick(e, at=T0 + timedelta(minutes=1), duration=timedelta(minutes=90))
    assert e.ends_at == T0 + timedelta(minutes=91)
    assert e.next_deadline() == e.ends_at
    assert not e.tick(T0 + timedelta(minutes=90))
    assert e.tick(T0 + timedelta(minutes=91))
    assert not e.bricked and e.sessions[-1].ended_by == "timer"


def test_emergency_unbricks_and_48h_reset():
    e = make(emergency_max=2)
    for i in range(2):
        brick(e, at=T0 + timedelta(minutes=i * 10))
        e.handle(Command(Action.EMERGENCY_UNBRICK), T0 + timedelta(minutes=i * 10 + 1))
        assert not e.bricked
    assert e.emergency_remaining == 0
    brick(e, at=T0 + timedelta(hours=1))
    with pytest.raises(BrickError) as err:
        e.handle(Command(Action.EMERGENCY_UNBRICK), T0 + timedelta(hours=1))
    assert err.value.code == engine.ERR_NO_EMERGENCY

    req = T0 + timedelta(hours=2)
    e.handle(Command(Action.REQUEST_RESET), req)
    assert e.emergency_reset_at == req + timedelta(hours=48)
    # Requesting again doesn't restart the clock.
    assert e.handle(Command(Action.REQUEST_RESET), req + timedelta(hours=10)).note == "already_requested"
    assert e.emergency_reset_at == req + timedelta(hours=48)

    assert not e.tick(req + timedelta(hours=47, minutes=59))
    assert e.emergency_remaining == 0
    assert e.tick(req + timedelta(hours=48))
    assert e.emergency_remaining == 2 and e.emergency_reset_at is None


def test_reset_not_needed_when_full():
    e = make()
    with pytest.raises(BrickError) as err:
        e.handle(Command(Action.REQUEST_RESET), T0)
    assert err.value.code == engine.ERR_RESET_NOT_NEEDED


def test_reset_partial_and_cancel():
    e = make(emergency_max=3)
    brick(e)
    e.handle(Command(Action.EMERGENCY_UNBRICK), T0)
    e.handle(Command(Action.REQUEST_RESET), T0)
    assert e.emergency_reset_at is not None
    e.handle(Command(Action.CANCEL_RESET), T0)
    assert e.emergency_reset_at is None


def test_auto_request_reset():
    e = make(emergency_max=1, auto_request_reset=True)
    brick(e)
    e.handle(Command(Action.EMERGENCY_UNBRICK), T0)
    assert e.emergency_reset_at == T0 + timedelta(hours=48)


def test_raising_max_does_not_refill():
    e = make(emergency_max=2)
    brick(e)
    e.handle(Command(Action.EMERGENCY_UNBRICK), T0)
    e.apply_settings(Settings(emergency_max=10))
    assert e.emergency_remaining == 1
    e.apply_settings(Settings(emergency_max=0))
    assert e.emergency_remaining == 0


def test_tags_locked_while_bricked():
    e = make()
    brick(e)
    with pytest.raises(BrickError) as err:
        e.handle(Command(Action.REGISTER_TAG, tag_id="AA"), T0)
    assert err.value.code == engine.ERR_LOCKED


def test_strict_manual_mode_switch_refused():
    e = make(strict=True)
    brick(e, mode_id="a")
    with pytest.raises(BrickError):
        e.handle(Command(Action.BRICK, Method.MANUAL, mode_id="b"), T0)
    brick(e, mode_id="b")  # automations may switch
    assert e.mode_id == "b"


def test_duplicate_event_ignored():
    e = make(strict=False)
    e.handle(Command(Action.BRICK, event_id="x"), T0)
    e.handle(Command(Action.UNBRICK, event_id="y"), T0)
    assert e.handle(Command(Action.BRICK, event_id="x"), T0).note == "duplicate"
    assert not e.bricked


def test_stale_offline_commands():
    e = make()
    brick(e, at=T0)
    # Phone emergency-unbricked offline *before* HA's last change -> charged,
    # but HA's newer state wins.
    e.handle(Command(Action.UNBRICK, Method.AUTOMATION), T0 + timedelta(minutes=30))
    brick(e, at=T0 + timedelta(minutes=40))
    r = e.handle(
        Command(Action.EMERGENCY_UNBRICK, occurred_at=T0 + timedelta(minutes=10)),
        T0 + timedelta(minutes=50),
    )
    assert r.note == "stale" and e.bricked and e.emergency_remaining == 4
    r = e.handle(
        Command(Action.UNBRICK, Method.AUTOMATION, occurred_at=T0 + timedelta(minutes=5)),
        T0 + timedelta(minutes=50),
    )
    assert r.note == "stale" and e.bricked


def test_offline_command_uses_occurred_at_and_clamps_future():
    e = make()
    e.handle(Command(Action.BRICK, occurred_at=T0 - timedelta(minutes=5)), T0)
    assert e.bricked_since == T0 - timedelta(minutes=5)
    e2 = make()
    e2.handle(Command(Action.BRICK, occurred_at=T0 + timedelta(days=1)), T0)
    assert e2.bricked_since == T0


def test_roundtrip_and_stats():
    e = make(strict=False)
    e.update_modes({"focus": "Focus"}, T0)
    # Two days in a row, an hour each (Sydney local days).
    day1 = datetime(2026, 11, 4, 10, tzinfo=SYD)
    day2 = datetime(2026, 11, 5, 10, tzinfo=SYD)
    for d in (day1, day2):
        e.handle(Command(Action.BRICK, mode_id="focus"), d)
        e.handle(Command(Action.UNBRICK), d + timedelta(hours=1))
    now = datetime(2026, 11, 5, 20, tzinfo=SYD)
    st = e.stats(now, SYD)
    assert st["today_seconds"] == 3600
    assert st["streak_days"] == 2
    assert st["sessions_total"] == 2
    assert st["longest_session_seconds"] == 3600

    restored = Engine.from_dict(e.to_dict(), e.settings)
    assert restored.to_dict() == e.to_dict()
    pub = restored.public_state(now, SYD)
    assert pub["modes"] == [{"id": "focus", "name": "Focus"}]
    assert "tags" not in pub


def test_unknown_mode_rejected_when_modes_known():
    e = make()
    e.update_modes({"focus": "Focus"}, T0)
    with pytest.raises(BrickError) as err:
        brick(e, mode_id="nope")
    assert err.value.code == engine.ERR_UNKNOWN_MODE
