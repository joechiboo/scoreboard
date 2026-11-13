import pytest

from scoreboard_ml.clips import roles, select_clips

SCORE = {"video": "a.mp4", "goal": 10.0, "shooter": "甲"}
ASSIST = {"video": "a.mp4", "goal": 20.0, "shooter": "乙", "assist": "甲"}
PUTBACK = {"video": "a.mp4", "goal": 30.0, "shooter": "乙", "involved": ["甲"]}
OTHER = {"video": "b.mp4", "goal": 5.0, "shooter": "乙"}
CLIPS = [SCORE, OTHER, ASSIST, PUTBACK]


def test_player_matches_any_role_in_file_order():
    assert select_clips(CLIPS, "甲") == [SCORE, ASSIST, PUTBACK]


def test_no_player_keeps_everything():
    assert select_clips(CLIPS, None) == CLIPS


def test_shooter_wins_over_other_roles():
    clip = {"video": "a.mp4", "goal": 1.0, "shooter": "甲", "assist": "甲", "involved": ["甲", "乙"]}
    assert roles(clip) == {"甲": "shooter", "乙": "involved"}


def test_missing_shooter_is_an_error():
    with pytest.raises(ValueError, match="沒有 shooter"):
        select_clips([{"video": "a.mp4", "goal": 1.0}], "甲")
