import numpy as np

from scoreboard_ml import Ball, Box
from scoreboard_ml.net_motion import NetMotion

REGION = Box(100, 100, 200, 200)


def frame(seed=0, net_shift=0):
    rng = np.random.default_rng(seed)
    img = np.full((300, 300, 3), 80, np.uint8)
    # 籃網：斜線紋路，net_shift 模擬晃動
    for x in range(100, 200, 10):
        img[100:200, (x + net_shift) % 300] = 230
    img += rng.integers(0, 3, img.shape, dtype=np.uint8)  # 感光雜訊
    return img


def draw_ball(img, ball):
    x1, y1, x2, y2 = ball.box().to_int()
    img[y1:y2, x1:x2] = (30, 100, 230)
    return img


def test_still_net_is_quiet():
    nm = NetMotion(REGION)
    nm.update(frame(0), None)
    assert nm.update(frame(1), None) < 0.02


def test_swaying_net_moves():
    nm = NetMotion(REGION)
    nm.update(frame(0), None)
    assert nm.update(frame(1, net_shift=4), None) > 0.04


def test_ball_passing_in_front_is_masked():
    nm = NetMotion(REGION)
    a, b = Ball(130, 130, 40, 40), Ball(160, 170, 40, 40)
    nm.update(draw_ball(frame(0), a), a)
    assert nm.update(draw_ball(frame(1), b), b) < 0.02
