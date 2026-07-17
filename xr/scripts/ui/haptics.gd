extends Node
## 控制器触觉反馈（Autoload 单例）。
## 调用方式：
##   Haptics.fire("click", controller)
##   Haptics.fire_both("error", left_controller, right_controller)
##   Haptics.fire_confirm(controller)  # 双段确认

# Godot 用这个字符串（而非空串）表示「该 tracker 未绑定 interaction profile」。
# 见 openxr_interface.cpp 的 INTERACTION_PROFILE_NONE。
const INTERACTION_PROFILE_NONE := "/interaction_profiles/none"

# 事件 -> [amplitude, duration]
# 注：confirm_a/confirm_b 通常通过 fire_confirm() 一起触发
const PROFILES: Dictionary = {
	"hover_cross": [0.15, 0.03],
	"click": [0.5, 0.05],
	"confirm_a": [0.7, 0.06],
	"confirm_b": [0.4, 0.05],
	"error": [0.8, 0.12],
	"connected": [0.6, 0.25],
	"exit_charging": [0.2, 0.05],
}

const UI_EVENT_TO_HAPTIC: Dictionary = {
	"hover": "hover_cross",
	"click": "click",
	"toggle_on": "click",
	"toggle_off": "click",
	"error": "error",
	"disconnected": "error",
	"exit_charging": "exit_charging",
	"stop_countdown": "exit_charging",
	"discovery_found": "hover_cross",
}

const LEFT_HAND_TRACKER := &"/user/hand_tracker/left"
const RIGHT_HAND_TRACKER := &"/user/hand_tracker/right"


func pulse(controller: XRController3D, amplitude: float, duration: float) -> void:
	## 在指定控制器上触发一次触觉脉冲。null 安全。
	if controller == null:
		return
	# 参数：action_name, frequency(0=默认), amplitude, duration, delay
	controller.trigger_haptic_pulse("haptic", 0.0, amplitude, duration, 0.0)


func fire(event: String, controller: XRController3D) -> void:
	## 按事件名查找配置并触发。未知事件给出警告。
	if not PROFILES.has(event):
		push_warning("Haptics: 未知事件 '%s'" % event)
		return
	if controller == null:
		return
	var profile: Array = PROFILES[event]
	pulse(controller, profile[0], profile[1])


func fire_both(event: String, left: XRController3D, right: XRController3D) -> void:
	## 在两只控制器上同时触发，任一为 null 时跳过该侧。
	if left != null:
		fire(event, left)
	if right != null:
		fire(event, right)


func fire_confirm(controller: XRController3D) -> void:
	## 双段确认反馈：立即播放 confirm_a，60ms 后播放 confirm_b。
	if controller == null:
		return
	fire("confirm_a", controller)
	# 通过场景树定时器延迟触发第二段
	var tree := get_tree()
	if tree == null:
		return
	var timer := tree.create_timer(0.06)
	timer.timeout.connect(func(): fire("confirm_b", controller))


func fire_ui_event(event: String, controller: XRController3D) -> void:
	## 将 UI 音效事件映射成控制器触觉反馈。
	if not should_use_controller_feedback(controller):
		return
	if event == "confirm" or event == "connected":
		fire_confirm(controller)
		return
	var haptic_event: String = UI_EVENT_TO_HAPTIC.get(event, "click")
	fire(haptic_event, controller)


func should_use_controller_feedback(controller: XRController3D) -> bool:
	## 光学手势追踪没有实体手柄可振动，应回退到 UI 音效。
	if controller == null:
		return false
	# 位姿由 XR_EXT_hand_interaction profile 驱动 == 裸手（即使 Godot 把它
	# 当作活跃的 XRController3D）。
	var profile := _pose_profile_for_controller(controller)
	if profile.find("hand_interaction") != -1:
		return false
	var tracker := _hand_tracker_for_controller(controller)
	if tracker != null and tracker.has_tracking_data:
		if tracker.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER:
			return true
		if tracker.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED:
			return false
		# SOURCE_UNKNOWN：不支持 XR_EXT_hand_tracking_data_source 的 runtime
		# （如 Pico OS）不上报 source。Pico 在握着手柄时也会上报光学手部
		# 数据，所以不能一概当裸手——改由位姿的 interaction profile 判断：
		# 真实手柄 profile（如 pico4_controller）说明手里握着手柄；没有绑定
		# profile 说明位姿不是手柄驱动的，按裸手处理。
		#
		# 注意：Godot 不会用空串表示「无 profile」，而是 INTERACTION_PROFILE_NONE
		# （"/interaction_profiles/none"）——建 tracker 时就是这个值，profile RID
		# 变 null 时也会重置回它（openxr_interface.cpp）。只判 is_empty() 永远
		# 匹配不到，会把「未绑定」误判成实体手柄。
		return not _profile_is_unbound(profile)
	return true


func _profile_is_unbound(profile: String) -> bool:
	return profile.is_empty() or profile == INTERACTION_PROFILE_NONE


func _pose_profile_for_controller(controller: XRController3D) -> String:
	var tracker := XRServer.get_tracker(controller.tracker)
	if tracker is XRPositionalTracker:
		return String((tracker as XRPositionalTracker).profile)
	return ""


func _hand_tracker_for_controller(controller: XRController3D) -> XRHandTracker:
	var tracker_name := String(controller.tracker).to_lower()
	var node_name := controller.name.to_lower()
	var hand_tracker_name := RIGHT_HAND_TRACKER
	if tracker_name.find("left") != -1 or node_name.find("left") != -1:
		hand_tracker_name = LEFT_HAND_TRACKER
	var tracker := XRServer.get_tracker(hand_tracker_name)
	if tracker is XRHandTracker:
		return tracker as XRHandTracker
	return null
