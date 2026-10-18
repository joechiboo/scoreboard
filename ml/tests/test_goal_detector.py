"""用合成的球軌跡測試進球判定。籃框框選框寬 100px，正常球徑約 53px。"""

import pytest

from scoreboard_ml import Ball, Box, GoalConfig, GoalDetector

RIM = Box(300, 200, 400, 220)
FPS = 30
BALL_D = 53


def path(waypoints, duration, d=BALL_D, t0=0.0, fps=FPS):
    """沿 waypoints 等速移動，回傳 [(t, Ball)]。"""
    n = max(2, int(duration * fps))
    segs = len(waypoints) - 1
    out = []
    for i in range(n):
        u = i / (n - 1) * segs
        k = min(int(u), segs - 1)
        f = u - k
        (xa, ya), (xb, yb) = waypoints[k], waypoints[k + 1]
        out.append((t0 + i / fps, Ball(xa + f * (xb - xa), ya + f * (yb - ya), d, d, 0.8)))
    return out


def run(frames, config=None, net_after=0.12, tail_s=1.0):
    """依序餵給 detector；球進入框下方後籃網晃動量為 net_after。回傳所有事件。"""
    det = GoalDetector(RIM, config)
    events = []
    below_seen = False
    last_t = frames[-1][0] if frames else 0.0
    for t, ball in frames:
        if ball is not None and ball.cy > RIM.y2:
            below_seen = True
        ev = det.update(t, ball, net_after if below_seen else 0.0)
        if ev:
            events.append(ev)
    # 球離開畫面後再跑一段，讓籃網確認完成
    for i in range(1, int(tail_s * FPS)):
        ev = det.update(last_t + i / FPS, None, net_after if below_seen else 0.0)
        if ev:
            events.append(ev)
    return events


MADE = [(280, 40), (350, 205), (350, 330)]


def test_made_shot():
    events = run(path(MADE, 0.6))
    assert len(events) == 1
    assert events[0].size_ratio == pytest.approx(0.53, abs=0.01)
    assert events[0].net_motion == pytest.approx(0.12)


def test_fast_ball_skips_rim_frames():
    # 低幀率：只拍到框上方一點與框下方一點
    frames = [(0.0, Ball(340, 150, BALL_D, BALL_D)), (0.1, Ball(352, 280, BALL_D, BALL_D))]
    assert len(run(frames)) == 1


def test_missing_detections_mid_flight():
    frames = path(MADE, 0.6)
    frames = [(t, None if 8 <= i <= 11 else b) for i, (t, b) in enumerate(frames)]
    assert len(run(frames)) == 1


def test_rim_out():
    assert run(path([(280, 40), (395, 200), (480, 120)], 0.6)) == []


def test_ball_going_up_through_rim():
    assert run(path([(350, 330), (350, 60)], 0.5)) == []


def test_ball_falls_beside_rim():
    assert run(path([(450, 40), (450, 330)], 0.6)) == []


def test_airball_in_front_looks_bigger():
    frames = path(MADE, 0.6, d=85)
    assert run(frames) == []
    assert len(run(frames, GoalConfig(use_size=False))) == 1


def test_airball_behind_looks_smaller():
    assert run(path(MADE, 0.6, d=28)) == []


def test_requires_net_motion():
    frames = path(MADE, 0.6)
    assert run(frames, net_after=0.0) == []
    assert len(run(frames, GoalConfig(use_net=False), net_after=0.0)) == 1


def test_too_slow_between_above_and_below():
    frames = [(0.0, Ball(350, 150, BALL_D, BALL_D)), (1.5, Ball(350, 280, BALL_D, BALL_D))]
    assert run(frames) == []


def test_cooldown_blocks_double_count():
    frames = path(MADE, 0.6) + path(MADE, 0.6, t0=1.0)
    assert len(run(frames)) == 1


def test_two_goals_after_cooldown():
    frames = path(MADE, 0.6) + path(MADE, 0.6, t0=3.0)
    assert len(run(frames)) == 2


def test_rolls_around_rim_then_drops_in():
    # 上方 → 碰框彈高 → 再從框內掉下
    wp = [(280, 40), (390, 200), (360, 150), (350, 205), (350, 330)]
    assert len(run(path(wp, 1.0))) == 1
