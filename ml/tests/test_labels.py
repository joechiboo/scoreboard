from scoreboard_ml.labels import load_labels, parse_time


def write(tmp_path, text):
    p = tmp_path / "labels.csv"
    p.write_text(text, encoding="utf-8")
    return p


def test_parse_time():
    assert parse_time("12.5") == 12.5
    assert parse_time("1:02.5") == 62.5


def test_only_made_shots_count(tmp_path):
    text = "時間,結果,分數\n# 第一節\n0:12.5,進,2\n0:20,沒進,\n1:02.5,進,3\n48,打框沒進\n"
    assert load_labels(write(tmp_path, text)) == [12.5, 62.5]


def test_time_only_rows_are_goals(tmp_path):
    assert load_labels(write(tmp_path, "t\n4.0\n1.0\n")) == [1.0, 4.0]
