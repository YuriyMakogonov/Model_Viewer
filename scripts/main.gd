extends Control
## Главное окно: 3D-просмотр слева, панель с информацией и расчётом справа.
## Интерфейс собирается в коде, чтобы его было проще читать и менять в одном месте.

const UNITS := [["мм", 1.0], ["см", 10.0], ["м", 1000.0], ["дюймы", 25.4]]
const SETTINGS_PATH := "user://settings.cfg"

const C_PANEL := Color("1d2226")
const C_VIEW := Color("2b3237")
const C_TEXT := Color("e8ecea")
const C_MUTED := Color("8f9a98")
const C_LINE := Color("3a4348")
const C_ACCENT := Color("f08c2e")
const C_GOOD := Color("69db7c")
const C_WARN := Color("ffd43b")
const C_BAD := Color("ff8787")

var font_ui: SystemFont
var font_mono: SystemFont

# 3D
var viewport: SubViewport
var camera: OrbitCamera
var model_root: Node3D
var pivot: Node3D
var mesh_instance: MeshInstance3D
var bed_node: MeshInstance3D
var surface_materials: Array[StandardMaterial3D] = []

# состояние
var model := {}            # результат загрузки + "analysis"
var file_info := {}        # имя, размер
var load_thread: Thread
var loading := false
var color_override := false

# элементы интерфейса
var hint: Label
var status: Label
var chk_auto: CheckBox
var chk_wire: CheckBox
var chk_bed: CheckBox
var color_btn: ColorPickerButton
var opt_units: OptionButton
var spin_scale: SpinBox
var chk_zup: CheckBox
var opt_material: OptionButton
var opt_diameter: OptionButton
var spin_infill: SpinBox
var spin_wall: SpinBox
var spin_support: SpinBox
var spin_price: SpinBox
var edit_currency: LineEdit
var spin_bed := {}
var v := {}                # подписи со значениями: ключ -> Label
var mat_list: VBoxContainer
var warn_label: Label
var fit_label: Label
var file_dialog: FileDialog


func _ready() -> void:
	_apply_display_scale()
	_build_theme()
	_build_ui()
	_build_world()
	_load_settings()
	get_window().files_dropped.connect(_on_files_dropped)

	var args := OS.get_cmdline_user_args()
	var to_open := ""
	for a in args:
		if a.get_extension().to_lower() in ["obj", "stl"]:
			to_open = a
	if to_open != "":
		load_path(to_open)
	else:
		_start_load(func(): return MeshLoader.make_sample_torus(), {"name": "Пример: тор 56 × 16 мм", "size": 0})

	var shot := args.find("--screenshot")
	if shot >= 0 and shot + 1 < args.size():
		_take_screenshot_and_quit(args[shot + 1])


func _apply_display_scale() -> void:
	var s := DisplayServer.screen_get_scale()
	if OS.get_name() == "Windows":
		s = DisplayServer.screen_get_dpi() / 96.0
	s = clampf(s, 1.0, 3.0)
	if s <= 1.0:
		return
	# Размер окна в настройках задан в логических точках: на Retina/HiDPI увеличиваем и окно, и интерфейс.
	var w := get_window()
	if w.mode == Window.MODE_WINDOWED:
		var screen := DisplayServer.screen_get_usable_rect(w.current_screen).size
		w.size = Vector2i(mini(int(1280 * s), screen.x), mini(int(800 * s), screen.y))
		w.move_to_center()
	w.content_scale_factor = s


# ================================================================ тема

func _build_theme() -> void:
	font_ui = SystemFont.new()
	font_ui.font_names = PackedStringArray(["Helvetica Neue", "Segoe UI", "Arial", "Noto Sans"])
	font_mono = SystemFont.new()
	font_mono.font_names = PackedStringArray(["Menlo", "Consolas", "DejaVu Sans Mono", "Courier New"])

	var t := Theme.new()
	t.default_font = font_ui
	t.default_font_size = 14
	t.set_color("font_color", "Label", C_TEXT)
	for cls in ["Button", "CheckBox", "OptionButton", "ColorPickerButton"]:
		t.set_color("font_color", cls, C_TEXT)
		t.set_color("font_hover_color", cls, Color.WHITE)
		t.set_color("font_pressed_color", cls, C_ACCENT)

	var btn := _box(Color("2c3439"), 6, C_LINE)
	var btn_h := _box(Color("353e44"), 6, C_ACCENT.darkened(0.2))
	for cls in ["Button", "OptionButton", "ColorPickerButton"]:
		t.set_stylebox("normal", cls, btn)
		t.set_stylebox("hover", cls, btn_h)
		t.set_stylebox("pressed", cls, btn_h)
		t.set_stylebox("focus", cls, _box(Color(0, 0, 0, 0), 6, C_ACCENT))
	var field := _box(Color("161a1d"), 5, C_LINE)
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", _box(Color("161a1d"), 5, C_ACCENT))
	t.set_color("font_color", "LineEdit", C_TEXT)
	t.set_stylebox("panel", "PanelContainer", _box(C_PANEL, 0, Color(0, 0, 0, 0)))
	t.set_stylebox("separator", "HSeparator", _line_box())
	theme = t


func _box(bg: Color, radius: int, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.border_color = border
	s.set_border_width_all(1 if border.a > 0 else 0)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	return s


func _line_box() -> StyleBoxLine:
	var s := StyleBoxLine.new()
	s.color = C_LINE
	s.thickness = 1
	return s


# ================================================================ интерфейс

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = C_PANEL
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# --- левая часть: панель инструментов + 3D
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 0)
	root.add_child(left)

	var bar_wrap := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		bar_wrap.add_theme_constant_override("margin_" + side, 8)
	left.add_child(bar_wrap)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	bar_wrap.add_child(bar)

	var b_open := Button.new()
	b_open.text = "Открыть модель…"
	b_open.add_theme_stylebox_override("normal", _box(C_ACCENT, 6, C_ACCENT))
	b_open.add_theme_stylebox_override("hover", _box(C_ACCENT.lightened(0.1), 6, C_ACCENT))
	b_open.add_theme_color_override("font_color", Color("1d2226"))
	b_open.add_theme_color_override("font_hover_color", Color("1d2226"))
	b_open.pressed.connect(_open_dialog)
	bar.add_child(b_open)

	var b_sample := Button.new()
	b_sample.text = "Пример"
	b_sample.tooltip_text = "Загрузить тестовый тор 56 × 16 мм"
	b_sample.pressed.connect(func(): _start_load(func(): return MeshLoader.make_sample_torus(), {"name": "Пример: тор 56 × 16 мм", "size": 0}))
	bar.add_child(b_sample)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	chk_auto = _check(bar, "Вращать", false)
	chk_auto.toggled.connect(func(on): camera.auto_rotate = on)
	chk_wire = _check(bar, "Каркас", false)
	chk_wire.toggled.connect(func(on): viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if on else Viewport.DEBUG_DRAW_DISABLED)
	chk_bed = _check(bar, "Стол", true)
	chk_bed.toggled.connect(func(on): bed_node.visible = on)

	color_btn = ColorPickerButton.new()
	color_btn.color = C_ACCENT
	color_btn.custom_minimum_size = Vector2(36, 0)
	color_btn.tooltip_text = "Цвет пластика. По умолчанию модель раскрашена по материалам из файла."
	color_btn.color_changed.connect(_on_color_picked)
	bar.add_child(color_btn)

	var b_reset := Button.new()
	b_reset.text = "Сбросить вид"
	b_reset.pressed.connect(func(): camera.reset_view())
	bar.add_child(b_reset)

	var view_wrap := SubViewportContainer.new()
	view_wrap.stretch = true
	view_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view_wrap.gui_input.connect(_on_view_input)
	view_wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	left.add_child(view_wrap)
	viewport = SubViewport.new()
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.handle_input_locally = false
	view_wrap.add_child(viewport)

	hint = Label.new()
	hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", C_MUTED)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view_wrap.add_child(hint)

	var st_wrap := MarginContainer.new()
	for side in ["left", "right"]:
		st_wrap.add_theme_constant_override("margin_" + side, 10)
	st_wrap.add_theme_constant_override("margin_top", 6)
	st_wrap.add_theme_constant_override("margin_bottom", 6)
	left.add_child(st_wrap)
	status = Label.new()
	status.add_theme_color_override("font_color", C_MUTED)
	status.add_theme_font_size_override("font_size", 12)
	status.text = "Левая кнопка — вращение · правая или Shift — сдвиг · колесо или щипок — масштаб · файл можно перетащить в окно"
	status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	st_wrap.add_child(status)

	# --- правая часть: информация
	var sep := VSeparator.new()
	sep.add_theme_stylebox_override("separator", _line_box())
	root.add_child(sep)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	root.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var pm := MarginContainer.new()
	pm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right"]:
		pm.add_theme_constant_override("margin_" + side, 18)
	pm.add_theme_constant_override("margin_top", 14)
	pm.add_theme_constant_override("margin_bottom", 18)
	scroll.add_child(pm)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	pm.add_child(col)

	# Файл
	var g := _section(col, "Файл")
	_kv(g, "name", "Имя")
	_kv(g, "format", "Формат")
	_kv(g, "size", "Размер файла")
	_kv(g, "tris", "Треугольники")
	_kv(g, "verts", "Вершины")
	_kv(g, "objects", "Объекты")
	_kv(g, "closed", "Сетка")
	warn_label = _note(col, "")
	warn_label.add_theme_color_override("font_color", C_WARN)

	# Материалы в файле
	_header(col, "Материалы в файле")
	mat_list = VBoxContainer.new()
	mat_list.add_theme_constant_override("separation", 4)
	col.add_child(mat_list)

	# Размеры
	g = _section(col, "Размеры")
	opt_units = OptionButton.new()
	for u in UNITS:
		opt_units.add_item(u[0])
	opt_units.tooltip_text = "В OBJ и STL единицы не записаны. Обычно это миллиметры."
	opt_units.item_selected.connect(func(_i): _on_transform_changed())
	_field(g, "Единицы файла", opt_units)
	spin_scale = _spin(1, 10000, 1, 100, " %")
	spin_scale.value_changed.connect(func(_x): _on_transform_changed())
	_field(g, "Масштаб", spin_scale)
	chk_zup = CheckBox.new()
	chk_zup.text = "Ось Z вверх"
	chk_zup.tooltip_text = "Включите, если модель лежит на боку. STL из CAD обычно сохраняют с осью Z вверх."
	chk_zup.toggled.connect(func(_on): _on_transform_changed())
	_field(g, "Ориентация", chk_zup)
	_kv(g, "dx", "Ширина (X)")
	_kv(g, "dy", "Глубина (Y)")
	_kv(g, "dz", "Высота (Z)")
	_kv(g, "volume", "Объём")
	_kv(g, "area", "Площадь поверхности")

	# Расход пластика
	g = _section(col, "Расход пластика (FDM)")
	opt_material = OptionButton.new()
	for m in PrintEstimate.MATERIALS:
		opt_material.add_item("%s · %s г/см³" % [m.name, _fmt(m.density, 2)])
	opt_material.item_selected.connect(func(_i): _on_print_changed())
	_field(g, "Пластик", opt_material)
	opt_diameter = OptionButton.new()
	opt_diameter.add_item("1,75 мм")
	opt_diameter.add_item("2,85 мм")
	opt_diameter.item_selected.connect(func(_i): _on_print_changed())
	_field(g, "Диаметр нити", opt_diameter)
	spin_infill = _spin(0, 100, 1, 20, " %")
	spin_infill.tooltip_text = "Заполнение внутренней части, как в слайсере"
	spin_infill.value_changed.connect(func(_x): _on_print_changed())
	_field(g, "Заполнение", spin_infill)
	spin_wall = _spin(0, 10, 0.1, 1.2, " мм")
	spin_wall.tooltip_text = "Стенки, верх и низ. Например, 3 периметра × 0,4 мм = 1,2 мм"
	spin_wall.value_changed.connect(func(_x): _on_print_changed())
	_field(g, "Толщина оболочки", spin_wall)
	spin_support = _spin(0, 200, 1, 0, " %")
	spin_support.tooltip_text = "Запас на поддержки и кайму, процент от массы модели"
	spin_support.value_changed.connect(func(_x): _on_print_changed())
	_field(g, "Поддержки, запас", spin_support)
	var price_row := HBoxContainer.new()
	spin_price = _spin(0, 1000000, 1, 25, "")
	spin_price.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin_price.value_changed.connect(func(_x): _on_print_changed())
	price_row.add_child(spin_price)
	edit_currency = LineEdit.new()
	edit_currency.text = "$"
	edit_currency.custom_minimum_size = Vector2(52, 0)
	edit_currency.max_length = 4
	edit_currency.text_changed.connect(func(_t): _on_print_changed())
	price_row.add_child(edit_currency)
	_field(g, "Цена за 1 кг", price_row)
	_kv(g, "grams", "Масса", true)
	_kv(g, "length", "Длина нити", true)
	_kv(g, "cost", "Стоимость", true)
	_kv(g, "printed", "Объём пластика")
	_kv(g, "perkg", "Из катушки 1 кг")

	# Стол принтера
	g = _section(col, "Стол принтера")
	for key in [["w", "Ширина", 220], ["d", "Глубина", 220], ["h", "Высота", 250]]:
		var s := _spin(10, 2000, 1, key[2], " мм")
		s.value_changed.connect(func(_x): _on_bed_changed())
		spin_bed[key[0]] = s
		_field(g, key[1], s)
	fit_label = _note(col, "")

	_note(col, "Расчёт приблизительный, без слайсера: ошибка обычно 10–20 %. Время печати и поддержки точно считает только слайсер (Cura, PrusaSlicer, Bambu Studio).").add_theme_color_override("font_color", C_MUTED)

	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.use_native_dialog = true
	file_dialog.title = "Открыть 3D-модель"
	file_dialog.filters = PackedStringArray(["*.obj, *.stl ; 3D-модели (OBJ, STL)"])
	file_dialog.file_selected.connect(load_path)
	add_child(file_dialog)


func _header(parent: Control, text: String) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	parent.add_child(box)
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_color_override("font_color", C_ACCENT)
	l.add_theme_font_size_override("font_size", 12)
	box.add_child(l)
	box.add_child(HSeparator.new())


func _section(parent: Control, title: String) -> GridContainer:
	_header(parent, title)
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 6)
	parent.add_child(g)
	return g


func _kv(g: GridContainer, key: String, title: String, strong := false) -> void:
	var k := Label.new()
	k.text = title
	k.add_theme_color_override("font_color", C_MUTED)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(k)
	var val := Label.new()
	val.text = "—"
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_override("font", font_mono)
	val.add_theme_font_size_override("font_size", 16 if strong else 13)
	if strong:
		val.add_theme_color_override("font_color", Color.WHITE)
	val.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	val.custom_minimum_size = Vector2(150, 0)
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(val)
	v[key] = val


func _field(g: GridContainer, title: String, control: Control) -> void:
	var k := Label.new()
	k.text = title
	k.add_theme_color_override("font_color", C_MUTED)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(k)
	control.custom_minimum_size.x = maxf(control.custom_minimum_size.x, 150)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(control)


func _note(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 12)
	l.custom_minimum_size = Vector2(300, 0)
	parent.add_child(l)
	return l


func _check(parent: Control, text: String, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	parent.add_child(c)
	return c


func _spin(mn: float, mx: float, step: float, value: float, suffix: String) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = value
	s.suffix = suffix
	s.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.select_all_on_focus = true
	return s


# ================================================================ 3D-сцена

func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = C_VIEW
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c9d3d6")
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	viewport.add_child(we)

	camera = OrbitCamera.new()
	camera.fov = 40
	viewport.add_child(camera)
	# Основной свет закреплён за камерой: модель освещена с любой стороны.
	var key := DirectionalLight3D.new()
	key.light_energy = 1.1
	key.rotation_degrees = Vector3(-25, -30, 0)
	camera.add_child(key)
	var top := DirectionalLight3D.new()
	top.light_energy = 0.35
	top.rotation_degrees = Vector3(-90, 0, 0)
	viewport.add_child(top)

	bed_node = MeshInstance3D.new()
	viewport.add_child(bed_node)
	model_root = Node3D.new()
	viewport.add_child(model_root)
	pivot = Node3D.new()
	model_root.add_child(pivot)
	mesh_instance = MeshInstance3D.new()
	pivot.add_child(mesh_instance)
	_rebuild_bed()


func _rebuild_bed() -> void:
	var w: float = spin_bed.w.value
	var d: float = spin_bed.d.value
	var h: float = spin_bed.h.value
	var step := 10.0
	var lines := PackedVector3Array()
	var x := -w / 2.0
	while x <= w / 2.0 + 0.001:
		lines.append(Vector3(x, 0, -d / 2.0))
		lines.append(Vector3(x, 0, d / 2.0))
		x += step
	var z := -d / 2.0
	while z <= d / 2.0 + 0.001:
		lines.append(Vector3(-w / 2.0, 0, z))
		lines.append(Vector3(w / 2.0, 0, z))
		z += step
	# рамка рабочей области
	var cs := [Vector3(-w, 0, -d), Vector3(w, 0, -d), Vector3(w, 0, d), Vector3(-w, 0, d)]
	for i in 4:
		var a: Vector3 = cs[i] * 0.5
		var b: Vector3 = cs[(i + 1) % 4] * 0.5
		lines.append_array([a + Vector3(0, h, 0), b + Vector3(0, h, 0), a, a + Vector3(0, h, 0)])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = lines
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.12)
	m.surface_set_material(0, mat)

	# сама пластина
	var plate := ArrayMesh.new()
	var parr := []
	parr.resize(Mesh.ARRAY_MAX)
	parr[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-w / 2, -0.05, -d / 2), Vector3(w / 2, -0.05, -d / 2), Vector3(w / 2, -0.05, d / 2),
		Vector3(-w / 2, -0.05, -d / 2), Vector3(w / 2, -0.05, d / 2), Vector3(-w / 2, -0.05, d / 2)])
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, parr)
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pmat.albedo_color = Color("232a2e")
	m.surface_set_material(1, pmat)
	bed_node.mesh = m


# ================================================================ загрузка

func _open_dialog() -> void:
	file_dialog.popup_centered_ratio(0.6)


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.get_extension().to_lower() in ["obj", "stl"]:
			load_path(f)
			return
	_show_error("Перетащите файл с расширением .obj или .stl.")


func load_path(path: String) -> void:
	var size := 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f:
		size = f.get_length()
		f.close()
	_start_load(func(): return MeshLoader.load_file(path), {"name": path.get_file(), "size": size, "path": path})


func _start_load(producer: Callable, info: Dictionary) -> void:
	if loading:
		return
	loading = true
	hint.text = "Загрузка «%s»…" % info.name
	hint.visible = true
	load_thread = Thread.new()
	load_thread.start(_worker.bind(producer, info))


## Выполняется в отдельном потоке: чтение, анализ и подготовка массивов для сетки.
func _worker(producer: Callable, info: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	var res: Dictionary = producer.call()
	if res.ok:
		var mc: int = res.materials.size()
		res["analysis"] = MeshAnalyzer.analyze(res.positions, res.indices, res.tri_mat, mc)
		res["surfaces"] = MeshAnalyzer.build_surfaces(res.positions, res.indices, res.tri_mat, mc)
		res.erase("positions")
		res.erase("indices")
		res.erase("tri_mat")
	res["load_ms"] = Time.get_ticks_msec() - t0
	_on_loaded.call_deferred(res, info)


func _on_loaded(res: Dictionary, info: Dictionary) -> void:
	load_thread.wait_to_finish()
	loading = false
	if not res.ok:
		_show_error(res.error)
		return
	hint.visible = false
	model = res
	file_info = info
	color_override = false

	var mesh := ArrayMesh.new()
	surface_materials.clear()
	for s in res.surfaces:
		if s.vertices.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = s.vertices
		arr[Mesh.ARRAY_NORMAL] = s.normals
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mat := StandardMaterial3D.new()
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.roughness = 0.6
		mat.set_meta("material_index", s.material)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
		surface_materials.append(mat)
	model.erase("surfaces")
	mesh_instance.mesh = mesh

	# STL из CAD почти всегда с осью Z вверх, OBJ — с осью Y вверх.
	chk_zup.set_pressed_no_signal(str(res.format).begins_with("STL"))
	_apply_colors()
	_on_transform_changed()
	get_window().title = "Model Viewer — %s" % info.name
	status.text = "Загружено за %s с · %s" % [_fmt(res.load_ms / 1000.0, 1), info.name]


func _show_error(msg: String) -> void:
	hint.visible = mesh_instance.mesh == null
	hint.text = msg
	status.text = "Ошибка: " + msg


func _on_color_picked(_c: Color) -> void:
	color_override = true
	_apply_colors()


func _apply_colors() -> void:
	for mat in surface_materials:
		var idx: int = mat.get_meta("material_index")
		mat.albedo_color = color_btn.color if color_override else model.materials[idx].color


# ================================================================ пересчёт

func _scale_k() -> float:
	return UNITS[opt_units.selected][1] * spin_scale.value / 100.0


## Габариты в мм: x — ширина, y — глубина, z — высота (как в слайсере).
func _dims_mm() -> Vector3:
	var s: Vector3 = model.analysis.aabb.size
	var d := Vector3(s.x, s.z, s.y) if not chk_zup.button_pressed else Vector3(s.x, s.y, s.z)
	return d * _scale_k()


func _on_transform_changed() -> void:
	if model.is_empty():
		return
	var a: Dictionary = model.analysis
	var k := _scale_k()
	mesh_instance.position = -a.aabb.get_center()
	pivot.rotation = Vector3(-PI / 2.0 if chk_zup.button_pressed else 0.0, 0, 0)
	model_root.scale = Vector3.ONE * k
	var dims := _dims_mm()
	model_root.position = Vector3(0, dims.z / 2.0, 0)
	camera.fit(model_root.position, dims.length() / 2.0)
	_update_info()


func _on_print_changed() -> void:
	_update_info()
	_save_settings()


func _on_bed_changed() -> void:
	_rebuild_bed()
	_update_info()
	_save_settings()


func _update_info() -> void:
	if model.is_empty():
		return
	var a: Dictionary = model.analysis
	var k := _scale_k()

	v.name.text = file_info.name
	v.name.tooltip_text = file_info.get("path", file_info.name)
	v.format.text = model.format
	v.size.text = _fmt_bytes(file_info.size) if file_info.size > 0 else "—"
	v.tris.text = _fmt(a.triangles, 0)
	v.verts.text = _fmt(a.vertices, 0)
	v.objects.text = _fmt(model.objects, 0)
	if a.closed:
		v.closed.text = "замкнутая ✓"
		v.closed.add_theme_color_override("font_color", C_GOOD)
	else:
		v.closed.text = "есть дыры"
		v.closed.add_theme_color_override("font_color", C_BAD)

	var warns := PackedStringArray()
	if a.open_edges > 0:
		warns.append("Открытых рёбер: %s. Модель не замкнута, объём и расход могут быть неточными. Исправьте её в слайсере или в Meshmixer." % _fmt(a.open_edges, 0))
	if a.nonmanifold_edges > 0:
		warns.append("Неправильных рёбер (общих для 3+ граней): %s." % _fmt(a.nonmanifold_edges, 0))
	if a.inverted and a.closed:
		warns.append("Нормали развёрнуты внутрь. Объём посчитан верно, но слайсер может ругаться.")
	if model.skipped_refs > 0:
		warns.append("Пропущено ссылок на несуществующие вершины: %s." % _fmt(model.skipped_refs, 0))
	warn_label.text = "\n".join(warns)
	warn_label.visible = not warns.is_empty()

	# материалы
	for c in mat_list.get_children():
		c.queue_free()
	for i in model.materials.size():
		var m: Dictionary = model.materials[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var sw := ColorRect.new()
		sw.color = m.color
		sw.custom_minimum_size = Vector2(14, 14)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(sw)
		var n := Label.new()
		n.text = m.name + ("" if m.from_file or model.format.begins_with("STL") else "  (цвет условный)")
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(n)
		var cnt := Label.new()
		var share: float = 100.0 * a.mat_tris[i] / maxf(a.triangles, 1)
		cnt.text = "%s треуг. · %s %%" % [_fmt(a.mat_tris[i], 0), _fmt(share, 0)]
		cnt.add_theme_font_override("font", font_mono)
		cnt.add_theme_font_size_override("font_size", 12)
		cnt.add_theme_color_override("font_color", C_MUTED)
		row.add_child(cnt)
		mat_list.add_child(row)
	var total := Label.new()
	total.text = "Всего материалов: %d" % model.materials.size()
	total.add_theme_color_override("font_color", C_MUTED)
	total.add_theme_font_size_override("font_size", 12)
	mat_list.add_child(total)

	# размеры
	var dims := _dims_mm()
	v.dx.text = _fmt(dims.x, 2) + " мм"
	v.dy.text = _fmt(dims.y, 2) + " мм"
	v.dz.text = _fmt(dims.z, 2) + " мм"
	var vol_mm3: float = a.volume * k * k * k
	var area_mm2: float = a.area * k * k
	v.volume.text = _fmt(vol_mm3 / 1000.0, 2) + " см³"
	v.area.text = _fmt(area_mm2 / 100.0, 2) + " см²"

	# расход
	var mat: Dictionary = PrintEstimate.MATERIALS[opt_material.selected]
	var dia := 1.75 if opt_diameter.selected == 0 else 2.85
	var est := PrintEstimate.compute(vol_mm3, area_mm2, mat.density, dia,
		spin_infill.value, spin_wall.value, spin_support.value, spin_price.value)
	v.grams.text = _fmt(est.grams, 1) + " г"
	v.length.text = _fmt(est.length_m, 2) + " м"
	v.cost.text = "%s %s" % [_fmt(est.cost, 2), edit_currency.text]
	v.printed.text = _fmt(est.printed_mm3 / 1000.0, 2) + " см³"
	v.perkg.text = ("%s шт." % _fmt(est.per_kg, 0)) if est.per_kg > 0 else "меньше 1 шт."

	# стол
	var bw: float = spin_bed.w.value
	var bd: float = spin_bed.d.value
	var bh: float = spin_bed.h.value
	if dims.z > bh:
		_set_fit("Не помещается: модель выше рабочей области на %s мм." % _fmt(dims.z - bh, 1), C_BAD)
	elif dims.x <= bw and dims.y <= bd:
		_set_fit("Помещается на стол.", C_GOOD)
	elif dims.y <= bw and dims.x <= bd:
		_set_fit("Помещается, если повернуть модель на 90° на столе.", C_WARN)
	else:
		_set_fit("Не помещается по ширине или глубине. Уменьшите масштаб или разрежьте модель.", C_BAD)


func _set_fit(text: String, color: Color) -> void:
	fit_label.text = text
	fit_label.add_theme_color_override("font_color", color)


# ================================================================ ввод в 3D

func _on_view_input(event: InputEvent) -> void:
	if camera and camera.handle_input(event):
		accept_event()


# ================================================================ настройки

func _save_settings() -> void:
	var c := ConfigFile.new()
	c.set_value("print", "material", opt_material.selected)
	c.set_value("print", "diameter", opt_diameter.selected)
	c.set_value("print", "infill", spin_infill.value)
	c.set_value("print", "wall", spin_wall.value)
	c.set_value("print", "support", spin_support.value)
	c.set_value("print", "price", spin_price.value)
	c.set_value("print", "currency", edit_currency.text)
	for key in spin_bed:
		c.set_value("bed", key, spin_bed[key].value)
	c.save(SETTINGS_PATH)


func _load_settings() -> void:
	var c := ConfigFile.new()
	if c.load(SETTINGS_PATH) != OK:
		return
	opt_material.select(c.get_value("print", "material", 0))
	opt_diameter.select(c.get_value("print", "diameter", 0))
	spin_infill.set_value_no_signal(c.get_value("print", "infill", 20))
	spin_wall.set_value_no_signal(c.get_value("print", "wall", 1.2))
	spin_support.set_value_no_signal(c.get_value("print", "support", 0))
	spin_price.set_value_no_signal(c.get_value("print", "price", 25))
	edit_currency.text = c.get_value("print", "currency", "$")
	for key in spin_bed:
		spin_bed[key].set_value_no_signal(c.get_value("bed", key, spin_bed[key].value))
	_rebuild_bed()


# ================================================================ форматирование

## Число по-русски: пробел между тысячами, запятая перед дробной частью.
static func _fmt(x: float, decimals: int) -> String:
	var s := ("%." + str(decimals) + "f") % x
	var neg := s.begins_with("-")
	if neg:
		s = s.substr(1)
	var parts := s.split(".")
	var ip := parts[0]
	var grouped := ""
	while ip.length() > 3:
		grouped = " " + ip.substr(ip.length() - 3) + grouped
		ip = ip.substr(0, ip.length() - 3)
	grouped = ip + grouped
	if parts.size() > 1:
		grouped += "," + parts[1]
	return ("−" if neg else "") + grouped


static func _fmt_bytes(n: int) -> String:
	if n < 1024:
		return "%d Б" % n
	if n < 1024 * 1024:
		return _fmt(n / 1024.0, 1) + " КБ"
	return _fmt(n / 1048576.0, 1) + " МБ"


# ================================================================ снимок для проверки

func _take_screenshot_and_quit(path: String) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
		if not loading and Time.get_ticks_msec() - t0 > 600:
			break
	for i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


func _exit_tree() -> void:
	if load_thread and load_thread.is_started():
		load_thread.wait_to_finish()
