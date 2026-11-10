package com.joechiboo.scoreboard.watch

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

private const val TAG = "ScoreStore"

/**
 * 比分以手錶自己存的為準：操作立刻生效並存檔，再排隊送到 Supabase，
 * 沒網路就留著，連上後照順序補送。
 *
 * 只有佇列清空時才採用伺服器的比分，否則還沒送出的操作會被舊資料蓋掉。
 * 所有狀態都只在主執行緒讀寫。
 */
object ScoreStore {
    var board by mutableStateOf<Scoreboard?>(null)
        private set

    /** 已經知道現在有沒有比賽（問過伺服器，或有上次的存檔）。 */
    var loaded by mutableStateOf(false)
        private set

    /** 最近一次連 Supabase 失敗。 */
    var offline by mutableStateOf(false)
        private set

    /** 還沒送到 Supabase 的操作數。 */
    var unsynced by mutableStateOf(0)
        private set

    /** 最近一次有人操作或打開畫面的時間（SystemClock.elapsedRealtime），藍牙服務用來判斷可以收工了沒。 */
    var lastActiveAt = SystemClock.elapsedRealtime()
        private set

    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val outbox = ArrayDeque<Op>()
    private var prefs: SharedPreferences? = null

    /** 佇列最前面那筆操作要寫進哪一場。離線開新局時，要等開新局送成功才知道新的 id。 */
    private var syncGameId: String? = null
    private var flushing = false
    private var mutations = 0

    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences("score", Context.MODE_PRIVATE)
        prefs = p
        try {
            board = p.getString("board", null)?.let { boardFromJson(JSONObject(it)) }
            syncGameId = p.getString("syncGameId", null)
            val saved = JSONArray(p.getString("outbox", "[]"))
            for (i in 0 until saved.length()) outbox.add(Op.fromJson(saved.getJSONObject(i)))
        } catch (e: Exception) {
            Log.w(TAG, "saved state unreadable, starting clean", e)
            outbox.clear()
        }
        unsynced = outbox.size
        loaded = board != null
    }

    /** 比分、模式、隊名或同步狀態變了就通知，在主執行緒呼叫。 */
    fun addListener(listener: () -> Unit) = listeners.add(listener)

    fun removeListener(listener: () -> Unit) = listeners.remove(listener)

    fun touch() {
        lastActiveAt = SystemClock.elapsedRealtime()
    }

    /** team 是 "A" 或 "B"。和網頁相同，分數不減到負的；沒生效時回傳 false。 */
    fun score(team: String, points: Int): Boolean {
        val current = board ?: return false
        if (points == 0 || points !in -3..3) return false
        val now = if (team == "A") current.scoreA else current.scoreB
        if (now + points < 0) return false
        board = if (team == "A") current.copy(scoreA = now + points) else current.copy(scoreB = now + points)
        enqueue(Op.Score(UUID.randomUUID().toString(), team, points))
        return true
    }

    fun toggleMode(): Boolean {
        val current = board ?: return false
        board = current.copy(halfCourt = !current.halfCourt)
        enqueue(Op.Mode(!current.halfCourt))
        return true
    }

    /** 目前這場存進紀錄，開新的一場，隊名和模式沿用。 */
    fun newGame(): Boolean {
        val current = board ?: return false
        board = current.copy(scoreA = 0, scoreB = 0)
        enqueue(Op.NewGame(current.teamA, current.teamB))
        return true
    }

    /** 有沒送出的就補送；都送完了才向伺服器拿最新比分（別的裝置可能改過）。 */
    suspend fun sync() {
        if (outbox.isNotEmpty() || flushing) {
            flush()
            return
        }
        val before = mutations
        try {
            val fetched = withContext(Dispatchers.IO) { ScoreApi.fetchLive() }
            offline = false
            // 等回應的期間手錶又有操作：這份是舊的，丟掉
            if (before != mutations || outbox.isNotEmpty()) return
            loaded = true
            if (fetched != null) syncGameId = fetched.gameId
            if (fetched != board) {
                board = fetched
                save()
            }
        } catch (e: Exception) {
            offline = true
        }
        notifyListeners()
    }

    fun flush() {
        if (flushing || outbox.isEmpty()) return
        flushing = true
        scope.launch {
            try {
                while (true) {
                    val op = outbox.firstOrNull() ?: break
                    val gameId = syncGameId
                    val newGameId = withContext(Dispatchers.IO) { op.send(gameId) }
                    if (newGameId != null) syncGameId = newGameId
                    outbox.removeFirst()
                    unsynced = outbox.size
                    offline = false
                    save()
                }
            } catch (e: Exception) {
                // 留在佇列等下次重試。被伺服器拒絕（HttpException）也不丟，寧可卡住讓人看到「未同步」，不要悄悄少分
                Log.w(TAG, "sync failed, ${outbox.size} queued", e)
                offline = true
            } finally {
                flushing = false
            }
            notifyListeners()
        }
    }

    private fun enqueue(op: Op) {
        outbox.add(op)
        unsynced = outbox.size
        mutations++
        touch()
        save()
        notifyListeners()
        flush()
    }

    private fun notifyListeners() {
        for (listener in listeners) listener()
    }

    private fun save() {
        val saved = JSONArray()
        for (op in outbox) saved.put(op.toJson())
        prefs?.edit()
            ?.putString("board", board?.let(::boardToJson)?.toString())
            ?.putString("syncGameId", syncGameId)
            ?.putString("outbox", saved.toString())
            ?.apply()
    }

    private fun boardToJson(b: Scoreboard) = JSONObject()
        .put("gameId", b.gameId)
        .put("teamA", b.teamA)
        .put("teamB", b.teamB)
        .put("scoreA", b.scoreA)
        .put("scoreB", b.scoreB)
        .put("halfCourt", b.halfCourt)

    private fun boardFromJson(j: JSONObject) = Scoreboard(
        gameId = j.getString("gameId"),
        teamA = j.getString("teamA"),
        teamB = j.getString("teamB"),
        scoreA = j.getInt("scoreA"),
        scoreB = j.getInt("scoreB"),
        halfCourt = j.getBoolean("halfCourt"),
    )

    private sealed interface Op {
        /** 在背景執行緒呼叫，失敗丟例外。開新局回傳新比賽的 id，其他回傳 null。 */
        fun send(gameId: String?): String?

        fun toJson(): JSONObject

        data class Score(val clientId: String, val team: String, val points: Int) : Op {
            override fun send(gameId: String?): String? {
                ScoreApi.addScore(checkNotNull(gameId) { "no game to score" }, team, points, clientId)
                return null
            }

            override fun toJson(): JSONObject = JSONObject()
                .put("type", "score").put("clientId", clientId).put("team", team).put("points", points)
        }

        data class Mode(val halfCourt: Boolean) : Op {
            override fun send(gameId: String?): String? {
                ScoreApi.setHalfCourt(checkNotNull(gameId) { "no game to switch" }, halfCourt)
                return null
            }

            override fun toJson(): JSONObject = JSONObject().put("type", "mode").put("halfCourt", halfCourt)
        }

        data class NewGame(val teamA: String, val teamB: String) : Op {
            override fun send(gameId: String?): String = ScoreApi.newGame(teamA, teamB)

            override fun toJson(): JSONObject = JSONObject().put("type", "newGame").put("teamA", teamA).put("teamB", teamB)
        }

        companion object {
            fun fromJson(j: JSONObject): Op = when (val type = j.getString("type")) {
                "score" -> Score(j.getString("clientId"), j.getString("team"), j.getInt("points"))
                "mode" -> Mode(j.getBoolean("halfCourt"))
                "newGame" -> NewGame(j.getString("teamA"), j.getString("teamB"))
                else -> error("unknown op $type")
            }
        }
    }
}
