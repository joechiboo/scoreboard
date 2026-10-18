"""籃框框選框、球、偵測區的幾何計算。座標皆為原始畫面的像素座標。"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Box:
    x1: float
    y1: float
    x2: float
    y2: float

    @property
    def width(self) -> float:
        return self.x2 - self.x1

    @property
    def height(self) -> float:
        return self.y2 - self.y1

    @property
    def cx(self) -> float:
        return (self.x1 + self.x2) / 2

    @property
    def cy(self) -> float:
        return (self.y1 + self.y2) / 2

    def clip(self, w: int, h: int) -> "Box":
        return Box(max(0, self.x1), max(0, self.y1), min(w, self.x2), min(h, self.y2))

    def to_int(self) -> tuple[int, int, int, int]:
        return int(self.x1), int(self.y1), int(self.x2), int(self.y2)


@dataclass(frozen=True)
class Ball:
    """單一幀偵測到的球（中心點與寬高）。"""

    cx: float
    cy: float
    w: float
    h: float
    conf: float = 1.0

    @property
    def diameter(self) -> float:
        return (self.w + self.h) / 2

    def box(self) -> Box:
        return Box(self.cx - self.w / 2, self.cy - self.h / 2, self.cx + self.w / 2, self.cy + self.h / 2)


def detection_roi(rim: Box, up: float = 2.5, down: float = 1.6, side: float = 0.6) -> Box:
    """由框選框推出偵測區：往上看球飛進來、往下看球從網子掉出，倍數以籃框寬度為單位。"""
    w = rim.width
    return Box(rim.x1 - side * w, rim.y1 - up * w, rim.x2 + side * w, rim.y2 + down * w)


def net_region(rim: Box, depth: float = 1.0) -> Box:
    """籃網所在區域：框選框正下方。"""
    return Box(rim.x1, rim.y2, rim.x2, rim.y2 + depth * rim.width)
