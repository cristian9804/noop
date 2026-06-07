package com.noop.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.noop.analytics.IllnessWatch
import com.noop.ble.LiveState
import com.noop.ble.WhoopBleClient
import com.noop.data.DailyMetric
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.protocol.CommandNumber
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * The single app-wide view model. Holds the BLE client and the Room-backed
 * repository, re-publishes the BLE [LiveState], maintains a spike-filtered/smoothed
 * BPM for the big read-outs, and runs the on-device illness watch over cached
 * daily metrics. Mirrors the macOS AppModel responsibilities (LiveState bridge,
 * `bpm` smoothing, health-alert string) without any networking.
 */
class AppViewModel(app: Application) : AndroidViewModel(app) {

    // BLE client — owns the GATT connection and emits LiveState.
    val ble = WhoopBleClient(app.applicationContext)

    // Offline store.
    private val repository: WhoopRepository =
        WhoopRepository(WhoopDatabase.get(app.applicationContext).whoopDao())

    val repo: WhoopRepository get() = repository

    /** Live connection + biometric snapshot, surfaced straight from the BLE client. */
    val live: StateFlow<LiveState> = ble.state

    // MARK: - Smoothed BPM (median over a short window, mirrors AppModel.bpm)

    private val hrWindow = ArrayDeque<Int>()
    private val hrWindowSize = 5
    private val _bpm = MutableStateFlow<Int?>(null)
    /** Spike-filtered, smoothed heart rate for the hero number. Null until data arrives. */
    val bpm: StateFlow<Int?> = _bpm.asStateFlow()

    // MARK: - Illness watch banner

    private val _healthAlert = MutableStateFlow<String?>(null)
    /** Non-null when the illness watch flags an early-warning pattern. Drives the banner. */
    val healthAlert: StateFlow<String?> = _healthAlert.asStateFlow()

    // MARK: - Today's cached metrics

    private val _today = MutableStateFlow<DailyMetric?>(null)
    val today: StateFlow<DailyMetric?> = _today.asStateFlow()

    /** Recent daily metrics (newest last), backing the Today grid + illness watch. */
    val recentDays: StateFlow<List<DailyMetric>> =
        repository.daysFlow("my-whoop")
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    init {
        // Smooth HR from each LiveState emission.
        viewModelScope.launch {
            ble.state.collect { state ->
                state.heartRate?.let { ingestHr(it) }
            }
        }
        // Recompute the illness banner + today's row whenever cached days change.
        viewModelScope.launch {
            recentDays.collect { days ->
                _today.value = days.lastOrNull()
                _healthAlert.value = IllnessWatch.evaluate(days)
            }
        }
    }

    // MARK: - HR smoothing (median filter)

    private fun ingestHr(raw: Int) {
        if (raw <= 0) return
        hrWindow.addLast(raw)
        while (hrWindow.size > hrWindowSize) hrWindow.removeFirst()
        val sorted = hrWindow.sorted()
        _bpm.value = sorted[sorted.size / 2]
    }

    // MARK: - Strap controls (thin pass-throughs to the BLE client)

    fun connect() = ble.connect()

    fun disconnect() {
        ble.disconnect()
        hrWindow.clear()
        _bpm.value = null
    }

    /** Toggle the strap's real-time HR stream on. */
    fun startRealtimeHr() = ble.send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1))

    /** Toggle the strap's real-time HR stream off. */
    fun stopRealtimeHr() = ble.send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(0))

    /** Ask the strap for its current battery level. */
    fun getBattery() = ble.send(CommandNumber.GET_BATTERY_LEVEL)

    /** Fire a haptic buzz on the strap (requires a bonded connection). */
    fun buzz(loops: Int = 2) = ble.buzz(loops)

    override fun onCleared() {
        super.onCleared()
        ble.disconnect()
    }
}
