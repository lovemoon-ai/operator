package com.godot.game.input

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot

private const val TAG = "OperatorInputPlugin"

/**
 * Small bridge for input policies that must be applied to Godot's Android
 * render view at runtime. The project-wide override_volume_buttons setting is
 * intentionally left disabled so the launcher, Teleop, and Live Feed retain
 * normal system-volume controls.
 */
class OperatorInputPlugin(private val host: Godot) : GodotPlugin(host) {

	override fun getPluginName(): String = "OperatorInputPlugin"

	@UsedByGodot
	@Suppress("FunctionName")
	fun set_volume_buttons_captured(captured: Boolean) {
		val currentActivity = activity
		if (currentActivity == null) {
			Log.w(TAG, "Cannot set volume-button capture without an Android activity")
			return
		}
		currentActivity.runOnUiThread {
			val inputHandler = host.renderView?.inputHandler
			if (inputHandler == null) {
				Log.w(TAG, "Cannot set volume-button capture before the render view is ready")
				return@runOnUiThread
			}
			inputHandler.setOverrideVolumeButtons(captured)
			Log.i(TAG, "Volume-button capture enabled=$captured")
		}
	}

	@UsedByGodot
	@Suppress("FunctionName")
	fun get_battery_percent(): Int {
		val currentActivity = activity ?: return -1
		val batteryIntent = currentActivity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
			?: return -1
		val level = batteryIntent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
		val scale = batteryIntent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
		if (level < 0 || scale <= 0) {
			Log.w(TAG, "Unable to read system battery level")
			return -1
		}
		return (level * 100 / scale).coerceIn(0, 100)
	}

	override fun onMainDestroy() {
		host.renderView?.inputHandler?.setOverrideVolumeButtons(false)
		super.onMainDestroy()
	}
}
