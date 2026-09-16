package com.godot.game.input

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

	override fun onMainDestroy() {
		host.renderView?.inputHandler?.setOverrideVolumeButtons(false)
		super.onMainDestroy()
	}
}
