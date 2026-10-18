"""進球判定：追蹤球的軌跡，不看單張畫面。

判定條件（後兩項可個別關閉，方便用影片比較效果）：
1. 軌跡：球先出現在框的上方，於 max_transit_s 內出現在框的下方，
   且上下兩點連線穿過框的位置落在框內（球太快、中間幀沒拍到也能判定）。
2. 大小：穿越時球的直徑 / 框寬 要接近真實比例（籃球 24cm / 籃框 45cm ≈ 0.53）。
   麵包球從框前面掉下時球看起來較大，從後面掉下時較小，藉此排除。
3. 籃網晃動：穿越後 net_window_s 內籃網區域要有明顯變化（net_motion 由呼叫端計算）。
判定後冷卻 cooldown_s，避免同一球重複計分。
"""

from dataclasses import dataclass

from .geometry import Ball, Box

BALL_TO_RIM_RATIO = 24 / 45


@dataclass
class GoalConfig:
    max_transit_s: float = 0.7  # 從框上方到框下方的最長時間
    above_margin: float = 0.5  # 「上方」區左右可超出框的寬度（倍數）
    crossing_tol: float = 0.1  # 穿越點可超出框左右的容許量（倍數）
    below_margin: float = 0.15  # 「下方」區左右可超出框的寬度（倍數）
    below_depth: float = 1.6  # 「下方」區的深度（框寬倍數），太下面就不算
    use_size: bool = True
    expected_ratio: float = BALL_TO_RIM_RATIO
    size_tol: float = 0.4  # 球框比例可偏離 expected_ratio 的比例
    use_net: bool = True
    net_window_s: float = 0.8
    net_threshold: float = 0.04
    cooldown_s: float = 2.0


@dataclass(frozen=True)
class GoalEvent:
    t: float  # 穿越籃框的時間（秒）
    confidence: float  # 偵測信心度（上下兩點平均）
    size_ratio: float
    net_motion: float | None


@dataclass
class _Pending:
    event: GoalEvent
    deadline: float
    peak_motion: float = 0.0


class GoalDetector:
    def __init__(self, rim: Box, config: GoalConfig | None = None):
        self.rim = rim
        self.cfg = config or GoalConfig()
        self._last_above: tuple[float, Ball] | None = None
        self._pending: _Pending | None = None
        self._cooldown_until = float("-inf")

    # ---------- 區域判斷 ----------

    def _is_above(self, b: Ball) -> bool:
        m = self.cfg.above_margin * self.rim.width
        return b.cy < self.rim.y1 and self.rim.x1 - m <= b.cx <= self.rim.x2 + m

    def _is_below(self, b: Ball) -> bool:
        m = self.cfg.below_margin * self.rim.width
        return (
            self.rim.y2 < b.cy <= self.rim.y2 + self.cfg.below_depth * self.rim.width
            and self.rim.x1 - m <= b.cx <= self.rim.x2 + m
        )

    def _crosses_rim(self, a: Ball, b: Ball) -> bool:
        """上下兩點連線在框的高度時，x 是否落在框內。"""
        if b.cy == a.cy:
            return False
        k = (self.rim.cy - a.cy) / (b.cy - a.cy)
        x = a.cx + k * (b.cx - a.cx)
        tol = self.cfg.crossing_tol * self.rim.width
        return self.rim.x1 - tol <= x <= self.rim.x2 + tol

    def _size_ratio(self, a: Ball, b: Ball) -> float:
        return (a.diameter + b.diameter) / 2 / self.rim.width

    def _size_ok(self, ratio: float) -> bool:
        if not self.cfg.use_size:
            return True
        lo = self.cfg.expected_ratio * (1 - self.cfg.size_tol)
        hi = self.cfg.expected_ratio * (1 + self.cfg.size_tol)
        return lo <= ratio <= hi

    # ---------- 主流程 ----------

    def update(self, t: float, ball: Ball | None, net_motion: float | None = None) -> GoalEvent | None:
        """每一幀呼叫一次。ball 為該幀偵測到的球（沒偵測到傳 None），
        net_motion 為籃網區域的變化量 0～1（不使用籃網確認時可省略）。
        回傳確認的進球事件，否則 None。"""
        confirmed = self._update_pending(t, net_motion)

        if ball is not None and t >= self._cooldown_until and self._pending is None:
            if self._is_above(ball):
                self._last_above = (t, ball)
            elif self._last_above is not None and self._is_below(ball):
                t_above, above = self._last_above
                if t - t_above <= self.cfg.max_transit_s and self._crosses_rim(above, ball):
                    self._last_above = None
                    ratio = self._size_ratio(above, ball)
                    if self._size_ok(ratio):
                        event = GoalEvent(
                            t=(t_above + t) / 2,
                            confidence=(above.conf + ball.conf) / 2,
                            size_ratio=ratio,
                            net_motion=None,
                        )
                        if self.cfg.use_net:
                            self._pending = _Pending(event, deadline=t + self.cfg.net_window_s)
                            confirmed = confirmed or self._update_pending(t, net_motion)
                        else:
                            confirmed = self._confirm(event, t)

        if self._last_above is not None and t - self._last_above[0] > self.cfg.max_transit_s:
            self._last_above = None
        return confirmed

    def _update_pending(self, t: float, net_motion: float | None) -> GoalEvent | None:
        p = self._pending
        if p is None:
            return None
        if net_motion is not None:
            p.peak_motion = max(p.peak_motion, net_motion)
        if p.peak_motion >= self.cfg.net_threshold:
            self._pending = None
            ev = GoalEvent(p.event.t, p.event.confidence, p.event.size_ratio, p.peak_motion)
            return self._confirm(ev, t)
        if t > p.deadline:
            self._pending = None  # 籃網沒晃：不算
        return None

    def _confirm(self, event: GoalEvent, t: float) -> GoalEvent:
        self._cooldown_until = t + self.cfg.cooldown_s
        self._last_above = None
        return event
