package com.joechiboo.scoreboard.watch

import android.os.Bundle
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import kotlin.math.abs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val TAG = "ScoreWatch"
private const val POLL_INTERVAL_MS = 2_000L
private const val RESET_CONFIRM_MS = 3_000L
private const val MODE_ZONE_RATIO = 0.38f // 畫面上方這個比例內是切換模式，要涵蓋模式按鈕
private val BUTTON_COLOR = Color(0xFF2E2E2E)
private val ACCENT = Color(0xFFF97316)

class MainActivity : ComponentActivity() {
    private var board by mutableStateOf<Scoreboard?>(null)
    private var loaded by mutableStateOf(false)
    private var offline by mutableStateOf(false)
    private var confirmingReset by mutableStateOf(false)
    private var resetTimeout: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 下鍵拿來歸零：系統還是會另外送返回，不攔的話每按一次 App 就被移到背景。
        // 離開 App 改用右滑或上鍵。
        onBackPressedDispatcher.addCallback(this) {}
        setContent {
            // 只在畫面看得到時輪詢，手錶熄屏就停，省電
            LaunchedEffect(Unit) {
                lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
                    while (true) {
                        refresh()
                        delay(POLL_INTERVAL_MS)
                    }
                }
            }

            MaterialTheme {
                ScoreScreen(
                    board = board,
                    loaded = loaded,
                    offline = offline,
                    confirmingReset = confirmingReset,
                    onToggleMode = ::toggleMode,
                    onTap = ::tap,
                    onSwipe = ::score,
                )
            }
        }
    }

    // 下鍵歸零。上鍵是電源鍵（KEYCODE_POWER），系統先攔走，App 收不到。
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode != KeyEvent.KEYCODE_BACK && event.keyCode != KeyEvent.KEYCODE_STEM_PRIMARY) {
            return super.dispatchKeyEvent(event)
        }
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) pressReset()
        return true
    }

    private fun toggleMode() {
        val current = board ?: return
        write { ScoreApi.setHalfCourt(current.gameId, !current.halfCourt) }
    }

    private fun tap(team: String) {
        score(team, board?.pointsPerPress ?: return)
    }

    private fun score(team: String, points: Int) {
        val current = board ?: return
        // 和網頁相同：分數不減到負的
        if ((if (team == "A") current.scoreA else current.scoreB) + points < 0) return
        write { ScoreApi.addScore(current.gameId, team, points) }
    }

    // 下鍵容易誤按，第一下只提示，時限內再按一次才執行
    private fun pressReset() {
        val current = board ?: return
        if (current.scoreA == 0 && current.scoreB == 0) return

        if (confirmingReset) {
            resetTimeout?.cancel()
            confirmingReset = false
            write { ScoreApi.newGame(current.teamA, current.teamB) }
        } else {
            confirmingReset = true
            window.decorView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            resetTimeout = lifecycleScope.launch {
                delay(RESET_CONFIRM_MS)
                confirmingReset = false
            }
        }
    }

    private fun write(action: () -> Unit) {
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) { action() }
                window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                refresh()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "write failed", e)
                window.decorView.performHapticFeedback(HapticFeedbackConstants.REJECT)
                offline = true
            }
        }
    }

    private suspend fun refresh() {
        try {
            board = withContext(Dispatchers.IO) { ScoreApi.fetchLive() }
            loaded = true
            offline = false
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            offline = true
        }
    }
}

@Composable
private fun ScoreScreen(
    board: Scoreboard?,
    loaded: Boolean,
    offline: Boolean,
    confirmingReset: Boolean,
    onToggleMode: () -> Unit,
    onTap: (String) -> Unit,
    onSwipe: (String, Int) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            // 和網頁相同，左半邊是 A、右半邊是 B：點一下加一球，上滑 +1，下滑 -1。
            // 點上方模式按鈕那一帶是切換全場／半場，不加分。按鈕很小，範圍放大比較好點。
            // 橫向滑動不處理，留給系統的右滑離開。
            .pointerInput(Unit) {
                val swipeDistance = 24.dp.toPx()
                val tapSlop = 8.dp.toPx()
                awaitEachGesture {
                    val down = awaitFirstDown()
                    var last = down.position
                    while (true) {
                        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                        last = change.position
                        if (!change.pressed) break
                    }
                    val team = if (down.position.x < size.width / 2) "A" else "B"
                    val dx = last.x - down.position.x
                    val dy = last.y - down.position.y
                    when {
                        abs(dy) >= swipeDistance && abs(dy) > abs(dx) -> onSwipe(team, if (dy < 0) 1 else -1)
                        abs(dx) < tapSlop && abs(dy) < tapSlop -> {
                            if (down.position.y < size.height * MODE_ZONE_RATIO) onToggleMode() else onTap(team)
                        }
                    }
                }
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        when {
            board != null -> {
                Text(
                    if (board.halfCourt) "半場" else "全場",
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(BUTTON_COLOR)
                        .padding(horizontal = 14.dp, vertical = 4.dp),
                    fontSize = 15.sp,
                    color = if (board.halfCourt) Color.White else ACCENT,
                )
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TeamScore(board.teamA, board.scoreA)
                    Text(":", fontSize = 36.sp, color = Color.Gray)
                    TeamScore(board.teamB, board.scoreB)
                }
            }
            offline -> Text("連不上計分板", fontSize = 16.sp, color = Color.White)
            loaded -> Text("目前沒有比賽", fontSize = 16.sp, color = Color.White)
            else -> Text("讀取中", fontSize = 16.sp, color = Color.White)
        }
        if (confirmingReset) {
            Spacer(Modifier.height(6.dp))
            Text("再按一次歸零", fontSize = 14.sp, color = ACCENT)
        }
        // 已有比分時斷線：比分留著，但要讓人知道它可能是舊的
        if (board != null && offline) {
            Spacer(Modifier.height(6.dp))
            Text("連線中斷", fontSize = 12.sp, color = ACCENT)
        }
    }
}

@Composable
private fun TeamScore(name: String, score: Int) {
    Column(
        modifier = Modifier.width(76.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(name, fontSize = 15.sp, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(score.toString(), fontSize = 44.sp, color = ACCENT)
    }
}
