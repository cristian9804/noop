package com.noop

import android.app.Application

/**
 * Application entry point.
 *
 * NOOP is a fully on-device WHOOP companion: it connects to the strap over BLE and
 * persists everything locally via Room. There is no network layer.
 *
 * This class is intentionally thin. The BLE client ([com.noop.ble.WhoopBleClient]) and
 * the data layer ([com.noop.data.WhoopRepository]) are owned and held by the
 * [com.noop.ui.AppViewModel], scoped to the Activity, so they live exactly as long as
 * the UI that drives them. Put process-wide one-time setup (logging, crash hooks) here
 * if it is ever needed.
 */
class NoopApplication : Application()
