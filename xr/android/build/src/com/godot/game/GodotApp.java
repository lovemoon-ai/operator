/**************************************************************************/
/*  GodotApp.java                                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

package com.godot.game;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;
import org.godotengine.godot.plugin.GodotPlugin;

import com.godot.game.camera.KotlinCameraPlugin;
import com.godot.game.video.KotlinVideoDecoderPlugin;

import android.os.Bundle;
import android.util.Log;

import androidx.activity.EdgeToEdge;
import androidx.core.splashscreen.SplashScreen;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Template activity for Godot Android builds.
 * Feel free to extend and modify this class for your custom logic.
 */
public class GodotApp extends GodotActivity {
	private static final String EXTRA_OPERATOR_MODE = "operator.mode";
	private static final String EXTRA_OPERATOR_MODE_LEGACY = "operator_mode";
	private static final String EXTRA_CAPTURE_INTERACTION_MODE = "operator.capture.interaction_mode";
	private static final String EXTRA_CAPTURE_AUTO_START = "operator.capture.auto_start";
	private static final String EXTRA_CAPTURE_AUTO_STOP_SECONDS = "operator.capture.auto_stop_seconds";
	private static final String EXTRA_CAPTURE_RGB_RESOLUTION = "operator.capture.rgb_resolution";
	private static final String EXTRA_CAPTURE_SAVE_ROOT = "operator.capture.save_root";
	private static final String EXTRA_CAPTURE_RGB_ONLY = "operator.capture.rgb_only";
	private static final String EXTRA_BODY_POSE_DEBUG = "operator.body_pose_debug";
	private static final String EXTRA_OPERATOR_AUTO_START = "operator.auto_start";
	private static final String EXTRA_OPERATOR_AUTO_START_LEGACY = "operator_auto_start";
	private static final String EXTRA_MUJOCO_DURATION = "mujoco.duration";
	private static final String EXTRA_MUJOCO_MIN_FRAMES = "mujoco.min.frames";
	// Headless synthetic teleop (cicd/07_so101_synthetic_teleop.sh): drives the
	// real teleop command path from a scripted operator, no headset/human.
	private static final String EXTRA_TELEOP_SYNTHETIC = "operator.teleop.synthetic";
	private static final String EXTRA_TELEOP_HOST = "operator.teleop.host";
	private static final String EXTRA_TELEOP_PORT = "operator.teleop.port";
	private static final String EXTRA_TELEOP_DURATION = "operator.teleop.duration";

	static {
		// .NET libraries.
		if (BuildConfig.FLAVOR.equals("mono")) {
			try {
				Log.v("GODOT", "Loading System.Security.Cryptography.Native.Android library");
				System.loadLibrary("System.Security.Cryptography.Native.Android");
			} catch (UnsatisfiedLinkError e) {
				Log.e("GODOT", "Unable to load System.Security.Cryptography.Native.Android library");
			}
		}
	}

	private final Runnable updateWindowAppearance = () -> {
		Godot godot = getGodot();
		if (godot != null) {
			godot.enableImmersiveMode(godot.isInImmersiveMode(), true);
			godot.enableEdgeToEdge(godot.isInEdgeToEdgeMode(), true);
			godot.setSystemBarsAppearance();
		}
	};

	@Override
	public void onCreate(Bundle savedInstanceState) {
		SplashScreen.installSplashScreen(this);
		EdgeToEdge.enable(this);
		super.onCreate(savedInstanceState);
	}

	@Override
	public Set<GodotPlugin> getHostPlugins(Godot godot) {
		Set<GodotPlugin> plugins = new HashSet<>();
		Set<GodotPlugin> basePlugins = super.getHostPlugins(godot);
		if (basePlugins != null) {
			plugins.addAll(basePlugins);
		}
		plugins.add(new KotlinCameraPlugin(godot));
		plugins.add(new KotlinVideoDecoderPlugin(godot));
		return plugins;
	}

	@Override
	public List<String> getCommandLine() {
		ArrayList<String> args = new ArrayList<>(super.getCommandLine());
		String operatorMode = getIntent().getStringExtra(EXTRA_OPERATOR_MODE);
		if (operatorMode == null || operatorMode.trim().isEmpty()) {
			operatorMode = getIntent().getStringExtra(EXTRA_OPERATOR_MODE_LEGACY);
		}
		if (operatorMode != null && !operatorMode.trim().isEmpty()) {
			ensureUserArgsDelimiter(args);
			args.add("--operator-mode");
			args.add(operatorMode.trim());
			Log.i("Operator", "Automation operator mode requested: " + operatorMode.trim());
		}
		appendIntentExtraArg(args, EXTRA_CAPTURE_INTERACTION_MODE, "--operator-capture-interaction-mode");
		appendIntentExtraArg(args, EXTRA_CAPTURE_AUTO_START, "--operator-capture-auto-start");
		appendIntentExtraArg(args, EXTRA_CAPTURE_AUTO_STOP_SECONDS, "--operator-capture-auto-stop-seconds");
		appendIntentExtraArg(args, EXTRA_CAPTURE_RGB_RESOLUTION, "--operator-capture-rgb-resolution");
		appendIntentExtraArg(args, EXTRA_CAPTURE_SAVE_ROOT, "--operator-capture-save-root");
		appendIntentExtraArg(args, EXTRA_CAPTURE_RGB_ONLY, "--operator-capture-rgb-only");
		appendIntentExtraArg(args, EXTRA_BODY_POSE_DEBUG, "--operator-body-pose-debug");
		if (readBooleanExtra(EXTRA_OPERATOR_AUTO_START) || readBooleanExtra(EXTRA_OPERATOR_AUTO_START_LEGACY)) {
			ensureUserArgsDelimiter(args);
			args.add("--operator-auto-start");
			Log.i("Operator", "Automation auto-start requested");
		}
		appendIntentExtraArg(args, EXTRA_MUJOCO_DURATION, "--mujoco-duration");
		appendIntentExtraArg(args, EXTRA_MUJOCO_MIN_FRAMES, "--mujoco-min-frames");
		appendIntentExtraArg(args, EXTRA_TELEOP_SYNTHETIC, "--operator-teleop-synthetic");
		appendIntentExtraArg(args, EXTRA_TELEOP_HOST, "--operator-teleop-host");
		appendIntentExtraArg(args, EXTRA_TELEOP_PORT, "--operator-teleop-port");
		appendIntentExtraArg(args, EXTRA_TELEOP_DURATION, "--operator-teleop-duration");
		// WP7 module test harness (tests/xr_module_harness.sh): only honored
		// by APKs exported with operator_feature_test_harness=true.
		appendIntentExtraArg(args, "operator_test_suite", "--operator-test-suite");
		appendIntentExtraArg(args, "operator_test_case", "--operator-test-case");
		return args;
	}

	private boolean readBooleanExtra(String key) {
		Bundle extras = getIntent().getExtras();
		if (extras == null || !extras.containsKey(key)) {
			return false;
		}
		Object value = extras.get(key);
		if (value instanceof Boolean) {
			return (Boolean)value;
		}
		if (value instanceof String) {
			String text = ((String)value).trim();
			return text.equalsIgnoreCase("true") || text.equals("1") || text.equalsIgnoreCase("yes");
		}
		return false;
	}

	private static void ensureUserArgsDelimiter(ArrayList<String> args) {
		if (!args.contains("--")) {
			args.add("--");
		}
	}

	private void appendIntentExtraArg(ArrayList<String> args, String extraName, String argName) {
		Bundle extras = getIntent().getExtras();
		if (extras == null || !extras.containsKey(extraName)) {
			return;
		}
		Object value = extras.get(extraName);
		if (value == null) {
			return;
		}
		String text = value.toString().trim();
		if (text.isEmpty()) {
			return;
		}
		ensureUserArgsDelimiter(args);
		args.add(argName);
		args.add(text);
		Log.i("Operator", "Automation extra requested: " + extraName + "=" + text);
	}

	@Override
	public void onResume() {
		super.onResume();
		updateWindowAppearance.run();
	}

	@Override
	public void onGodotMainLoopStarted() {
		super.onGodotMainLoopStarted();
		runOnUiThread(updateWindowAppearance);
	}
}
