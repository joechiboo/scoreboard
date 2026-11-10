package com.joechiboo.scoreboard.watch

import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject

data class Scoreboard(
    val gameId: String,
    val teamA: String,
    val teamB: String,
    val scoreA: Int,
    val scoreB: Int,
    val halfCourt: Boolean,
) {
    /** 和網頁點一下相同：半場 +1、全場 +2。 */
    val pointsPerPress: Int get() = if (halfCourt) 1 else 2
}

/** 伺服器有回應但拒絕了；和連不上不同，重送也不會成功。 */
class HttpException(val code: Int) : Exception("HTTP $code")

/** 連線資訊和 web/、app/ 相同，是可以公開的金鑰。所有方法都要在背景執行緒呼叫，失敗會丟例外。 */
object ScoreApi {
    private const val BASE_URL = "https://fyfmhdoluahjvncmgcaq.supabase.co/rest/v1"
    private const val KEY = "sb_publishable_r32ZjBy2q2nbXrMZXSp2XA_7UAR_tVk"
    private const val TIMEOUT_MS = 5_000

    /** 回傳進行中的比賽，沒有比賽時回傳 null。 */
    fun fetchLive(): Scoreboard? {
        val games = get("games?status=eq.live&select=id,team_a_name,team_b_name,mode")
        if (games.length() == 0) return null
        val game = games.getJSONObject(0)
        val gameId = game.getString("id")

        val scores = get("game_scores?game_id=eq.$gameId&select=score_a,score_b")
        val score = if (scores.length() > 0) scores.getJSONObject(0) else null

        return Scoreboard(
            gameId = gameId,
            teamA = game.getString("team_a_name"),
            teamB = game.getString("team_b_name"),
            scoreA = score?.getInt("score_a") ?: 0,
            scoreB = score?.getInt("score_b") ?: 0,
            halfCourt = game.getString("mode") == "half",
        )
    }

    /**
     * team 是 "A" 或 "B"。clientId 由手錶產生：送出後沒收到回應而重送時，
     * 資料庫認得是同一筆，不會重複計分（和偵測 App 的做法相同）。
     */
    fun addScore(gameId: String, team: String, points: Int, clientId: String) {
        send(
            "POST",
            "score_events?on_conflict=client_id",
            JSONObject()
                .put("client_id", clientId)
                .put("game_id", gameId)
                .put("team", team)
                .put("points", points)
                .put("source", "manual"),
            prefer = "resolution=ignore-duplicates,return=minimal",
        )
    }

    /** 和網頁的開新局相同：目前這場存進紀錄，新的一場比分 0:0，模式沿用。回傳新比賽的 id。 */
    fun newGame(teamA: String, teamB: String): String {
        val body = send(
            "POST",
            "rpc/new_game",
            JSONObject()
                .put("p_team_a_name", teamA)
                .put("p_team_b_name", teamB),
            prefer = null,
        )
        return JSONObject(body).getString("id")
    }

    /** 所有裝置一起換；和網頁相同，開新局會沿用。 */
    fun setHalfCourt(gameId: String, halfCourt: Boolean) {
        send(
            "PATCH",
            "games?id=eq.$gameId",
            JSONObject().put("mode", if (halfCourt) "half" else "full"),
        )
    }

    private fun send(method: String, path: String, body: JSONObject, prefer: String? = "return=minimal"): String {
        val connection = open(path)
        try {
            connection.requestMethod = method
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            if (prefer != null) connection.setRequestProperty("Prefer", prefer)
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = connection.responseCode
            if (code !in 200..299) throw HttpException(code)
            return connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private fun get(path: String): JSONArray {
        val connection = open(path)
        try {
            val code = connection.responseCode
            if (code != 200) throw HttpException(code)
            return JSONArray(connection.inputStream.bufferedReader().use { it.readText() })
        } finally {
            connection.disconnect()
        }
    }

    private fun open(path: String): HttpURLConnection {
        val connection = URL("$BASE_URL/$path").openConnection() as HttpURLConnection
        connection.connectTimeout = TIMEOUT_MS
        connection.readTimeout = TIMEOUT_MS
        connection.setRequestProperty("apikey", KEY)
        return connection
    }
}
