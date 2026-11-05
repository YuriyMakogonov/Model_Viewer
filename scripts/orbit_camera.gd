class_name OrbitCamera
extends Camera3D
## Камера, которая вращается вокруг модели.
## Мышь: левая кнопка — вращение, правая/средняя (или Shift + левая) — сдвиг, колесо — масштаб.
## Трекпад: два пальца — вращение, Shift + два пальца — сдвиг, щипок — масштаб.
## Сенсорный экран: один палец — вращение, два пальца — сдвиг и масштаб (щипок).

var target := Vector3.ZERO
var yaw := deg_to_rad(35.0)
var pitch := deg_to_rad(25.0)
var distance := 120.0
var auto_rotate := false

const ROTATE_SPEED := 0.008
const MIN_PITCH := -1.55
const MAX_PITCH := 1.55

var _home := {}

# активные касания: индекс пальца -> позиция; для жестов двумя пальцами
var _touches := {}
var _pinch_dist := 0.0
var _pinch_center := Vector2.ZERO


func _process(delta: float) -> void:
	if auto_rotate:
		yaw += delta * 0.5
	_apply()


func _apply() -> void:
	pitch = clampf(pitch, MIN_PITCH, MAX_PITCH)
	var dir := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	position = target + dir * distance
	look_at(target, Vector3.UP)


## Показать сферу (центр, радиус) целиком и запомнить этот вид для «Сбросить вид».
func fit(center: Vector3, radius: float) -> void:
	radius = maxf(radius, 0.001)
	target = center
	distance = radius / sin(deg_to_rad(fov) * 0.5) * 1.15
	yaw = deg_to_rad(35.0)
	pitch = deg_to_rad(25.0)
	near = maxf(distance * 0.002, 0.001)
	far = maxf(distance * 50.0, 10000.0)
	_home = {"target": target, "distance": distance}
	_apply()


func reset_view() -> void:
	if _home.is_empty():
		return
	target = _home.target
	distance = _home.distance
	yaw = deg_to_rad(35.0)
	pitch = deg_to_rad(25.0)


func _zoom(factor: float) -> void:
	distance = clampf(distance * factor, near * 2.0, far * 0.5)


func _pan(rel: Vector2) -> void:
	var b := global_transform.basis
	var k := distance * 0.0016
	target += (-b.x * rel.x + b.y * rel.y) * k


func _touch_gesture_reset() -> void:
	if _touches.size() == 2:
		var p: Array = _touches.values()
		_pinch_dist = (p[0] as Vector2).distance_to(p[1])
		_pinch_center = ((p[0] as Vector2) + (p[1] as Vector2)) * 0.5


func handle_input(event: InputEvent) -> bool:
	# Касания. Первый палец браузер/Godot дублирует событиями мыши — они дают вращение.
	if event is InputEventScreenTouch:
		var idx: int = event.index
		if event.pressed:
			_touches[idx] = event.position
		else:
			_touches.erase(idx)
		_touch_gesture_reset()
		return false
	if event is InputEventScreenDrag:
		var idx: int = event.index
		_touches[idx] = event.position
		if _touches.size() == 2:
			var p: Array = _touches.values()
			var d := (p[0] as Vector2).distance_to(p[1])
			var c := ((p[0] as Vector2) + (p[1] as Vector2)) * 0.5
			if _pinch_dist > 1.0 and d > 1.0:
				_zoom(_pinch_dist / d)
			_pan(c - _pinch_center)
			_pinch_dist = d
			_pinch_center = c
			return true
		return false
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(0.9 if event.factor == 0.0 else pow(0.9, event.factor))
				return true
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(1.0 / 0.9 if event.factor == 0.0 else pow(1.0 / 0.9, event.factor))
				return true
	elif event is InputEventMouseMotion:
		if _touches.size() >= 2:
			return true  # во время щипка не вращаем
		var m: int = event.button_mask
		var left: bool = (m & MOUSE_BUTTON_MASK_LEFT) != 0
		var shift: bool = event.shift_pressed
		var pan: bool = (m & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE)) != 0 or (left and shift)
		if pan:
			_pan(event.relative)
			return true
		if left:
			yaw -= event.relative.x * ROTATE_SPEED
			pitch += event.relative.y * ROTATE_SPEED
			return true
	elif event is InputEventMagnifyGesture:
		_zoom(1.0 / maxf(event.factor, 0.01))
		return true
	elif event is InputEventPanGesture:
		if event.shift_pressed:
			_pan(-event.delta * 8.0)
		else:
			yaw -= event.delta.x * 0.04
			pitch -= event.delta.y * 0.04
		return true
	return false
