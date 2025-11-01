package com.example.gesture_inject

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val CHANNEL = "com.example.gesture_inject/signal"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"getWifiRssiDbm" -> {
						try {
							val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
							val info = wifiManager.connectionInfo
							val rssi = info?.rssi ?: -127
							result.success(rssi)
						} catch (e: Exception) {
							result.error("ERR", e.message, null)
						}
					}
					else -> result.notImplemented()
				}
			}
	}
}
