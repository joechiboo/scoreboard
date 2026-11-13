"""從一場的 clips.json 挑出要剪的進球。

clips.json 是一場一份、人眼核對過的進球清單，格式同 plan.json，每顆多三個欄位：
  "shooter": "乙"          最後出手得分的人
  "assist": "甲"           助攻的人，沒有就省略
  "involved": ["丙"]       其他有參與的人（例如出手沒進、被隊友補進），沒有就省略
"""


def roles(clip: dict) -> dict[str, str]:
    """回傳 {球員: 角色}，角色是 shooter / assist / involved。"""
    found = {}
    for name in clip.get("involved", []):
        found[name] = "involved"
    if clip.get("assist"):
        found[clip["assist"]] = "assist"
    if "shooter" not in clip:
        raise ValueError(f"{clip['video']} @{clip['goal']} 沒有 shooter，請先核對誰得分")
    found[clip["shooter"]] = "shooter"
    return found


def select_clips(clips: list[dict], player: str | None) -> list[dict]:
    """挑出 player 有參與的進球，順序照檔案；player 為 None 時全收。"""
    if player is None:
        return list(clips)
    return [clip for clip in clips if player in roles(clip)]
