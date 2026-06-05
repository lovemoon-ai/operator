extends Node
## 控制器触觉反馈（Autoload 单例）。
## 调用方式：
##   Haptics.fire("click", controller)
##   Haptics.fire_both("error", left_controller, right_controller)
##   Haptics.fire_confirm(controller)  # 双段确认

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
	var tracker := _hand_tracker_for_controller(controller)
	if tracker != null and tracker.has_tracking_data:
		return tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	return true


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
