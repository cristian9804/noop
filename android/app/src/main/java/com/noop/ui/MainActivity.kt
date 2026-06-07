package com.noop.ui

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import com.noop.BuildConfig
import com.noop.data.DemoSeeder
import com.noop.data.WhoopRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Single-activity host. Requests the runtime BLE permissions the strap connection
 * needs, then renders the Compose tree under [NoopTheme]. The design system is
 * dark-only, so we draw edge-to-edge over the near-black [Palette.surfaceBase].
 */
class MainActivity : ComponentActivity() {

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            // Permission results flow back into the BLE client's own runtime checks;
            // the UI simply reflects connection state. No blocking here.
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        // Demo build only: preload a full synthetic dataset so every screen is populated
        // out of the box (no strap, no import). No-op once seeded; never runs on the full app.
        if (BuildConfig.ENABLE_DEMO) {
            lifecycleScope.launch(Dispatchers.IO) {
                runCatching { DemoSeeder.seedIfEmpty(WhoopRepository.from(applicationContext)) }
            }
        }

        requestBlePermissions()

        setContent {
            NoopTheme {
                AppRoot()
            }
        }
    }

    /** Request the BLE permissions appropriate to the running OS version. */
    private fun requestBlePermissions() {
        val needed = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+: granular Bluetooth permissions.
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                // Pre-12: location is required for BLE scanning.
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }.toTypedArray()

        if (needed.isNotEmpty()) permissionLauncher.launch(needed)
    }
}
