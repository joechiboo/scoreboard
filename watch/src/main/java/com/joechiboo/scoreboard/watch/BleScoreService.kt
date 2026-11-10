package com.joechiboo.scoreboard.watch

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

private const val TAG = "BleScore"
private const val TICK_MS = 15_000L
private const val IDLE_STOP_MS = 2 * 60 * 60 * 1000L
private const val NOTIFICATION_ID = 1
private const val CHANNEL_ID = "ble"

/**
 * 手錶用藍牙（BLE）把比分直接送給場邊的平板，不經過網路。
 * 手錶是周邊裝置：廣播自己，平板的計分板網頁用 Web Bluetooth 連上來。UUID 和格式要和 web/src/watch-ble.js 一致。
 *
 * - 狀態（可讀、會通知）7 bytes：版本 1、A 分數低／高位、B 分數低／高位、
 *   旗標（bit0 半場、bit1 有比賽、bit2 有還沒上傳的操作）、隊名版本
 * - 隊名（可讀）："A隊\nB隊" 的 UTF-8；隊名版本變了平板才重讀
 * - 指令（可寫）：[0] 請手錶向伺服器更新；[1, 隊伍 0/1, 分數 -3～3] 平板上按的加減分
 *
 * 用前景服務是為了手錶熄屏、回到錶面後連線還在。
 */
@SuppressLint("MissingPermission") // 啟動前 MainActivity 已經確認過藍牙權限；少了就整個不啟動
class BleScoreService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var server: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var stateChar: BluetoothGattCharacteristic? = null

    // 以下只在主執行緒讀寫
    private val subscribers = LinkedHashSet<BluetoothDevice>()
    private val inFlight = HashSet<BluetoothDevice>()
    private val sent = HashMap<BluetoothDevice, ByteArray>()

    @Volatile private var state = ByteArray(0)
    @Volatile private var names = ByteArray(0)
    private var namesRev = 0

    private val onStoreChange: () -> Unit = { publish() }

    private val tick = object : Runnable {
        override fun run() {
            if (SystemClock.elapsedRealtime() - ScoreStore.lastActiveAt > IDLE_STOP_MS) {
                stopSelf()
                return
            }
            ScoreStore.flush()
            inFlight.clear() // 通知的回報萬一沒回來，不要永遠卡住
            publish()
            main.postDelayed(this, TICK_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onCreate() {
        super.onCreate()
        ScoreStore.init(this)
        goForeground()
        refreshPayload()
        try {
            openServer()
        } catch (e: Exception) {
            Log.w(TAG, "BLE unavailable", e)
            status = "藍牙無法使用"
            stopSelf()
            return
        }
        ScoreStore.addListener(onStoreChange)
        main.postDelayed(tick, TICK_MS)
    }

    override fun onDestroy() {
        main.removeCallbacks(tick)
        ScoreStore.removeListener(onStoreChange)
        scope.cancel()
        try {
            advertiser?.stopAdvertising(advertiseCallback)
            server?.close()
        } catch (e: Exception) {
            Log.w(TAG, "close failed", e)
        }
        server = null
        if (status != "藍牙無法使用") status = ""
        super.onDestroy()
    }

    // 失敗就當一般服務繼續跑：App 在前景時照樣能用，只是熄屏後可能被系統收掉
    private fun goForeground() {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "比分藍牙連線", NotificationManager.IMPORTANCE_LOW),
            )
            val notification = Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle("計分板")
                .setContentText("比分正用藍牙傳給平板")
                .setOngoing(true)
                .build()
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } catch (e: Exception) {
            Log.w(TAG, "foreground refused", e)
        }
    }

    private fun openServer() {
        val manager = getSystemService(BluetoothManager::class.java)
        advertiser = checkNotNull(manager.adapter?.bluetoothLeAdvertiser) { "bluetooth off or no advertiser" }

        val stateC = BluetoothGattCharacteristic(
            STATE_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        stateC.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            ),
        )
        val namesC = BluetoothGattCharacteristic(
            NAMES_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        val commandC = BluetoothGattCharacteristic(
            COMMAND_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(stateC)
        service.addCharacteristic(namesC)
        service.addCharacteristic(commandC)

        stateChar = stateC
        server = checkNotNull(manager.openGattServer(this, gattCallback)) { "openGattServer returned null" }
        // 服務加好（onServiceAdded）才開始廣播，平板連上來時才找得到
        check(server!!.addService(service)) { "addService refused" }
    }

    private fun advertise(withName: Boolean) {
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        advertisingWithName = withName
        try {
            if (withName) {
                // 手錶名稱放在掃描回應，平板的選擇清單才看得到名字
                val response = AdvertiseData.Builder().setIncludeDeviceName(true).build()
                advertiser?.startAdvertising(settings, data, response, advertiseCallback)
            } else {
                advertiser?.startAdvertising(settings, data, advertiseCallback)
            }
        } catch (e: Exception) {
            Log.w(TAG, "advertise failed", e)
            status = "藍牙無法廣播"
        }
    }

    private var advertisingWithName = true

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            main.post { showLinkStatus() }
        }

        override fun onStartFailure(errorCode: Int) {
            Log.w(TAG, "advertise failed: $errorCode")
            main.post {
                // 名稱太長塞不下時，不帶名稱再試一次
                if (advertisingWithName && errorCode == ADVERTISE_FAILED_DATA_TOO_LARGE) advertise(withName = false)
                else status = "藍牙無法廣播（$errorCode）"
            }
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            main.post {
                if (status == BluetoothGatt.GATT_SUCCESS) advertise(withName = true)
                else BleScoreService.status = "藍牙無法使用（$status）"
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState != BluetoothProfile.STATE_DISCONNECTED) return
            main.post {
                subscribers.remove(device)
                inFlight.remove(device)
                sent.remove(device)
                showLinkStatus()
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val value = when (characteristic.uuid) {
                STATE_UUID -> state
                NAMES_UUID -> names
                else -> null
            }
            respond(device, requestId, offset, value)
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            val ok = characteristic.uuid == COMMAND_UUID && !preparedWrite && value != null && value.isNotEmpty()
            if (ok) main.post { runCommand(value!!) }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, 0, null)
            }
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor,
        ) {
            // 回答得慢一拍沒關係：這個值平板不會拿來用
            main.post {
                val value = if (device in subscribers) ENABLE_NOTIFICATION else DISABLE_NOTIFICATION
                respond(device, requestId, offset, value)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            val isCccd = descriptor.uuid == CCCD_UUID
            if (isCccd) {
                val enable = value != null && value.isNotEmpty() && value[0].toInt() != 0
                main.post {
                    if (enable) subscribers.add(device) else subscribers.remove(device)
                    sent.remove(device)
                    showLinkStatus()
                    publish()
                }
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, if (isCccd) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, 0, null)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                inFlight.remove(device)
                pushTo(device) // 等回報的期間比分又變了就補送
            }
        }
    }

    private fun respond(device: BluetoothDevice, requestId: Int, offset: Int, value: ByteArray?) {
        val gatt = server ?: return
        if (value == null || offset > value.size) {
            gatt.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
        } else {
            gatt.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value.copyOfRange(offset, value.size))
        }
    }

    private fun runCommand(value: ByteArray) {
        when (value[0].toInt()) {
            // 平板看到伺服器的比分變了（別的裝置改的），請手錶去拿
            0 -> scope.launch { ScoreStore.sync() }
            1 -> if (value.size >= 3) ScoreStore.score(if (value[1].toInt() == 0) "A" else "B", value[2].toInt())
        }
    }

    private fun refreshPayload() {
        val board = ScoreStore.board
        val newNames = (if (board == null) "" else "${board.teamA}\n${board.teamB}").toByteArray()
        if (!newNames.contentEquals(names)) {
            names = newNames
            namesRev = (namesRev + 1) and 0xFF
        }
        val a = board?.scoreA ?: 0
        val b = board?.scoreB ?: 0
        val flags = (if (board?.halfCourt == true) 1 else 0) or
            (if (board != null) 2 else 0) or
            (if (ScoreStore.unsynced > 0) 4 else 0)
        state = byteArrayOf(
            1,
            a.toByte(), (a shr 8).toByte(),
            b.toByte(), (b shr 8).toByte(),
            flags.toByte(),
            namesRev.toByte(),
        )
    }

    private fun publish() {
        refreshPayload()
        for (device in subscribers) pushTo(device)
    }

    // 一次只能有一筆通知在路上；送出去的和現在的一樣就不重送
    private fun pushTo(device: BluetoothDevice) {
        val gatt = server ?: return
        val characteristic = stateChar ?: return
        val value = state
        if (device !in subscribers || device in inFlight || sent[device]?.contentEquals(value) == true) return
        val ok = try {
            if (Build.VERSION.SDK_INT >= 33) {
                gatt.notifyCharacteristicChanged(device, characteristic, false, value) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = value
                @Suppress("DEPRECATION")
                gatt.notifyCharacteristicChanged(device, characteristic, false)
            }
        } catch (e: Exception) {
            Log.w(TAG, "notify failed", e)
            false
        }
        if (ok) {
            inFlight.add(device)
            sent[device] = value
        }
    }

    private fun showLinkStatus() {
        status = if (subscribers.isEmpty()) "等平板連線" else "平板已連線"
    }

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("7b1d0001-5c0a-4e7e-9d3a-6f2c8a41b0e5")
        val STATE_UUID: UUID = UUID.fromString("7b1d0002-5c0a-4e7e-9d3a-6f2c8a41b0e5")
        val NAMES_UUID: UUID = UUID.fromString("7b1d0003-5c0a-4e7e-9d3a-6f2c8a41b0e5")
        val COMMAND_UUID: UUID = UUID.fromString("7b1d0004-5c0a-4e7e-9d3a-6f2c8a41b0e5")
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private val ENABLE_NOTIFICATION = byteArrayOf(1, 0)
        private val DISABLE_NOTIFICATION = byteArrayOf(0, 0)

        /** 顯示在手錶畫面上的藍牙狀態，空字串表示沒在跑。 */
        var status by mutableStateOf("")
            private set

        /** 只能在 App 在前景時呼叫。 */
        fun start(context: Context) {
            try {
                context.startService(Intent(context, BleScoreService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "start refused", e)
            }
        }
    }
}
