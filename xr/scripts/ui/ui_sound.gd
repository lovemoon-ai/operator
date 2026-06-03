extends Node
## UI 音效总线（Autoload 单例）。
## 运行时使用 PCM 合成短促的 UI 反馈音效，避免引入二进制音频资源。
## 调用方式：
##   UISoundBus.play("click")            # HUD 2D 播放
##   UISoundBus.play_at(node3d, "click") # 空间化播放

const SAMPLE_RATE: int = 22050
const POOL_SIZE: int = 6
const OUTPUT_GAIN_DB: float = 6.0
const ATTACK_MS: float = 4.0   # 攻击包络，避免起始爆音
const RELEASE_MS: float = 8.0  # 释放包络，避免结尾爆音

# 波形类型常量（内部使用）
const _WAVE_SINE: int = 0
const _WAVE_SQUARE: int = 1

# 预合成的一次性 WAV 流，按事件名索引
var _streams: Dictionary[String, AudioStreamWAV] = {}
# 2D 播放器池，支持音效重叠
var _players: Array[AudioStreamPlayer] = []
var _next_player_idx: int = 0
var _debug_play_count := 0


func _ready() -> void:
	# 预生成所有事件音效
	_build_streams()
	# 创建播放器池
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)


# ---------- 公共 API ----------

func play(event: String, volume_db: float = 0.0) -> void:
	## 2D 播放（HUD 风格，无空间化）。
	if not _streams.has(event):
		push_warning("UISoundBus: 未知事件 '%s'" % event)
		return
	var player := _players[_next_player_idx]
	_next_player_idx = (_next_player_idx + 1) % POOL_SIZE
	player.stream = _streams[event]
	player.volume_db = volume_db + OUTPUT_GAIN_DB
	player.play()
	if _debug_play_count < 12:
		_debug_play_count += 1
		print("QcUISound play event=%s volume_db=%.1f" % [event, player.volume_db])


func play_at(node3d: Node3D, event: String, volume_db: float = 0.0) -> void:
	## 在指定 3D 节点位置播放，结束后自动释放。
	## 若 node3d 为 null 或未入树，退化为 2D 播放。
	if node3d == null or not node3d.is_inside_tree():
		play(event, volume_db)
		return
	if not _streams.has(event):
		push_warning("UISoundBus: 未知事件 '%s'" % event)
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = _streams[event]
	p.volume_db = volume_db
	p.bus = "Master"
	node3d.add_child(p)
	# 播放完毕后自动清理
	p.finished.connect(p.queue_free)
	p.play()


# ---------- 预合成 ----------

func _build_streams() -> void:
	# hover：500Hz 方波，30ms，低音量
	_streams["hover"] = _make_tone(650.0, 0.055, _WAVE_SQUARE, 0.32)
	# click：800Hz 方波，50ms
	_streams["click"] = _make_tone(800.0, 0.060, _WAVE_SQUARE, 0.46)
	# toggle_on：600→900Hz 正弦双音
	_streams["toggle_on"] = _make_sequence([
		{"freq": 600.0, "dur": 0.040, "wave": _WAVE_SINE, "gain": 0.35, "gap": 0.0},
		{"freq": 900.0, "dur": 0.040, "wave": _WAVE_SINE, "gain": 0.35, "gap": 0.0},
	])
	# toggle_off：900→600Hz 正弦双音
	_streams["toggle_off"] = _make_sequence([
		{"freq": 900.0, "dur": 0.040, "wave": _WAVE_SINE, "gain": 0.35, "gap": 0.0},
		{"freq": 600.0, "dur": 0.040, "wave": _WAVE_SINE, "gain": 0.35, "gap": 0.0},
	])
	# confirm：600/800/1200Hz 上升三音
	_streams["confirm"] = _make_sequence([
		{"freq": 600.0, "dur": 0.080, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.0},
		{"freq": 800.0, "dur": 0.080, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.0},
		{"freq": 1200.0, "dur": 0.080, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.0},
	])
	# error：180Hz 方波，120ms
	_streams["error"] = _make_tone(180.0, 0.120, _WAVE_SQUARE, 0.4)
	# connected：四音上升，每个之间 30ms 间隔
	_streams["connected"] = _make_sequence([
		{"freq": 600.0, "dur": 0.100, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.030},
		{"freq": 900.0, "dur": 0.100, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.030},
		{"freq": 1200.0, "dur": 0.100, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.030},
		{"freq": 1500.0, "dur": 0.100, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.0},
	])
	# disconnected：三音下降
	_streams["disconnected"] = _make_sequence([
		{"freq": 1000.0, "dur": 0.090, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.0},
		{"freq": 700.0, "dur": 0.090, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.0},
		{"freq": 450.0, "dur": 0.090, "wave": _WAVE_SINE, "gain": 0.4, "gap": 0.0},
	])
	# discovery_found：1800Hz 单音 60ms，线性衰减
	_streams["discovery_found"] = _make_tone(1800.0, 0.060, _WAVE_SINE, 0.35, true)
	# exit_charging：200→900Hz 线性扫频 300ms
	_streams["exit_charging"] = _make_sweep(200.0, 900.0, 0.300, _WAVE_SINE, 0.35)


# ---------- 合成原语 ----------

func _make_tone(freq: float, duration: float, wave: int, gain: float, decay: bool = false) -> AudioStreamWAV:
	## 生成单一音调的 WAV 流。
	var n_samples := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n_samples)
	for i in n_samples:
		var t := float(i) / float(SAMPLE_RATE)
		var s := _osc(wave, freq, t) * gain
		if decay:
			# 线性振幅衰减（从 1 衰减到 0）
			s *= 1.0 - (float(i) / float(n_samples))
		samples[i] = s
	_apply_envelope(samples)
	return _samples_to_wav(samples)


func _make_sequence(notes: Array) -> AudioStreamWAV:
	## 生成多个音符顺序拼接的 WAV 流。每个 note 字典需包含 freq/dur/wave/gain/gap。
	var all_samples := PackedFloat32Array()
	for note in notes:
		var freq: float = note["freq"]
		var dur: float = note["dur"]
		var wave: int = note["wave"]
		var gain: float = note["gain"]
		var gap: float = note.get("gap", 0.0)
		var n_samples := int(dur * SAMPLE_RATE)
		var note_samples := PackedFloat32Array()
		note_samples.resize(n_samples)
		for i in n_samples:
			var t := float(i) / float(SAMPLE_RATE)
			note_samples[i] = _osc(wave, freq, t) * gain
		_apply_envelope(note_samples)
		all_samples.append_array(note_samples)
		if gap > 0.0:
			var gap_samples := int(gap * SAMPLE_RATE)
			var silence := PackedFloat32Array()
			silence.resize(gap_samples)
			# PackedFloat32Array 默认为 0
			all_samples.append_array(silence)
	return _samples_to_wav(all_samples)


func _make_sweep(freq_start: float, freq_end: float, duration: float, wave: int, gain: float) -> AudioStreamWAV:
	## 生成线性扫频（chirp）WAV 流。使用相位累加保证连续。
	var n_samples := int(duration * SAMPLE_RATE)
	var samples := PackedFloat32Array()
	samples.resize(n_samples)
	var phase := 0.0
	for i in n_samples:
		var alpha := float(i) / float(n_samples)
		var f := lerpf(freq_start, freq_end, alpha)
		phase += TAU * f / float(SAMPLE_RATE)
		var s := 0.0
		if wave == _WAVE_SQUARE:
			s = 1.0 if sin(phase) >= 0.0 else -1.0
		else:
			s = sin(phase)
		samples[i] = s * gain
	_apply_envelope(samples)
	return _samples_to_wav(samples)


func _osc(wave: int, freq: float, t: float) -> float:
	## 振荡器：返回 [-1, 1] 范围的波形值。
	var phase := TAU * freq * t
	if wave == _WAVE_SQUARE:
		return 1.0 if sin(phase) >= 0.0 else -1.0
	return sin(phase)


func _apply_envelope(samples: PackedFloat32Array) -> void:
	## 对样本就地应用 4ms 线性攻击 + 8ms 线性释放包络，消除爆音。
	var n := samples.size()
	if n == 0:
		return
	var attack := int(ATTACK_MS * 0.001 * SAMPLE_RATE)
	var release := int(RELEASE_MS * 0.001 * SAMPLE_RATE)
	attack = min(attack, n / 2)
	release = min(release, n / 2)
	for i in attack:
		var g := float(i) / float(attack)
		samples[i] = samples[i] * g
	for i in release:
		var g := float(i) / float(release)
		var idx := n - 1 - i
		samples[idx] = samples[idx] * g


func _samples_to_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	## 将归一化的 float32 样本转换为 16-bit PCM AudioStreamWAV。
	var n := samples.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		var s := clampf(samples[i], -1.0, 1.0)
		var v := int(s * 32767.0)
		# 小端 16-bit 有符号
		if v < 0:
			v += 65536
		bytes[i * 2] = v & 0xFF
		bytes[i * 2 + 1] = (v >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = bytes
	return wav
