class_name MeshLoader
extends RefCounted
## Загрузка OBJ и STL во время работы программы.
##
## Результат load_file / parse_*:
## {
##   ok: bool, error: String, format: String,
##   positions: PackedVector3Array  — вершины в единицах файла,
##   indices: PackedInt32Array      — по 3 индекса на треугольник,
##   tri_mat: PackedInt32Array      — индекс материала для каждого треугольника,
##   materials: Array[Dictionary]   — {name, color, from_file},
##   objects: int, skipped_refs: int
## }

const PALETTE := [
	Color("f08c2e"), Color("4dabf7"), Color("69db7c"), Color("f783ac"),
	Color("ffd43b"), Color("9775fa"), Color("63e6be"), Color("ff8787"),
]
const DEFAULT_MAT := "без материала"


static func load_file(path: String) -> Dictionary:
	var ext := path.get_extension().to_lower()
	if ext not in ["obj", "stl"]:
		return _fail("Формат .%s не поддерживается. Откройте файл OBJ или STL." % ext)
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return _fail("Файл пустой или не открывается (%s)." % error_string(FileAccess.get_open_error()))
	return load_bytes(path.get_file(), bytes, path.get_base_dir())


## Разбор уже прочитанного файла. В браузере файл приходит байтами, без пути на диске.
static func load_bytes(file_name: String, bytes: PackedByteArray, base_dir: String = "") -> Dictionary:
	match file_name.get_extension().to_lower():
		"obj":
			return parse_obj(bytes.get_string_from_utf8(), base_dir)
		"stl":
			return parse_stl(bytes)
	return _fail("Формат .%s не поддерживается. Откройте файл OBJ или STL." % file_name.get_extension())


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


# ---------------------------------------------------------------- OBJ

static func parse_obj(text: String, base_dir: String = "") -> Dictionary:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var tri_mat := PackedInt32Array()
	var mat_names: Array[String] = []
	var mat_lookup := {}
	var current := -1
	var objects := 0
	var mtllibs: Array[String] = []
	var face := PackedInt32Array()
	var skipped := 0

	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line.length() < 2 or line[0] == "#":
			continue
		if "\t" in line:
			line = line.replace("\t", " ")
		var c := line[0]
		if c == "v" and line[1] == " ":
			var p := line.substr(2).split_floats(" ", false)
			if p.size() >= 3:
				positions.append(Vector3(p[0], p[1], p[2]))
		elif c == "f" and line[1] == " ":
			face.clear()
			var nv := positions.size()
			for tok in line.substr(2).split(" ", false):
				var vi := tok.get_slice("/", 0).to_int()
				vi = nv + vi if vi < 0 else vi - 1
				if vi < 0 or vi >= nv:
					skipped += 1
					continue
				face.append(vi)
			if face.size() < 3:
				continue
			if current < 0:
				current = _mat_index(DEFAULT_MAT, mat_names, mat_lookup)
			for k in range(1, face.size() - 1):
				indices.append(face[0])
				indices.append(face[k])
				indices.append(face[k + 1])
				tri_mat.append(current)
		elif line.begins_with("usemtl"):
			var name := line.substr(6).strip_edges()
			current = _mat_index(name if name != "" else DEFAULT_MAT, mat_names, mat_lookup)
		elif line.begins_with("mtllib"):
			mtllibs.append(line.substr(6).strip_edges())
		elif c == "o" and line[1] == " ":
			objects += 1

	if indices.is_empty():
		return _fail("В файле нет граней (строк «f»). Возможно, это облако точек или линии, а не сетка.")

	var kd := {}
	if base_dir != "":
		for lib in mtllibs:
			kd.merge(_read_mtl_colors(base_dir.path_join(lib)))

	var materials: Array[Dictionary] = []
	for i in mat_names.size():
		var n := mat_names[i]
		materials.append({
			"name": n,
			"color": kd.get(n, PALETTE[i % PALETTE.size()]),
			"from_file": kd.has(n),
		})

	return {
		"ok": true, "format": "OBJ",
		"positions": positions, "indices": indices, "tri_mat": tri_mat,
		"materials": materials, "objects": maxi(objects, 1), "skipped_refs": skipped,
	}


static func _mat_index(name: String, names: Array[String], lookup: Dictionary) -> int:
	if lookup.has(name):
		return lookup[name]
	names.append(name)
	lookup[name] = names.size() - 1
	return names.size() - 1


## Читает цвета Kd из .mtl, если файл лежит рядом с моделью.
static func _read_mtl_colors(path: String) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var cur := ""
	for raw in FileAccess.get_file_as_string(path).split("\n", false):
		var line := raw.strip_edges().replace("\t", " ")
		if line.begins_with("newmtl"):
			cur = line.substr(6).strip_edges()
		elif line.begins_with("Kd ") and cur != "":
			var p := line.substr(3).split_floats(" ", false)
			if p.size() >= 3:
				out[cur] = Color(p[0], p[1], p[2])
	return out


# ---------------------------------------------------------------- STL

static func parse_stl(bytes: PackedByteArray) -> Dictionary:
	# Бинарный STL: 80 байт заголовка, uint32 число треугольников, по 50 байт на треугольник.
	# Проверяем его первым: заголовок бинарного файла тоже может начинаться со «solid».
	if bytes.size() >= 84:
		var n := bytes.decode_u32(80)
		if 84 + n * 50 == bytes.size():
			return _parse_stl_binary(bytes, n)
	var head := bytes.slice(0, mini(bytes.size(), 512)).get_string_from_ascii().strip_edges()
	if head.begins_with("solid"):
		return _parse_stl_ascii(bytes.get_string_from_ascii())
	return _fail("Файл STL повреждён: размер не совпадает с числом треугольников в заголовке.")


static func _parse_stl_binary(bytes: PackedByteArray, n: int) -> Dictionary:
	if n == 0:
		return _fail("В файле STL нет треугольников.")
	var positions := PackedVector3Array()
	positions.resize(n * 3)
	var indices := PackedInt32Array()
	indices.resize(n * 3)
	for i in n:
		var o := 84 + i * 50 + 12
		for j in 3:
			var b := o + j * 12
			positions[i * 3 + j] = Vector3(bytes.decode_float(b), bytes.decode_float(b + 4), bytes.decode_float(b + 8))
			indices[i * 3 + j] = i * 3 + j
	return _stl_result(positions, indices, 1, "STL (бинарный)")


static func _parse_stl_ascii(text: String) -> Dictionary:
	var positions := PackedVector3Array()
	var solids := 0
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line.begins_with("vertex"):
			var p := line.substr(6).replace("\t", " ").split_floats(" ", false)
			if p.size() >= 3:
				positions.append(Vector3(p[0], p[1], p[2]))
		elif line.begins_with("solid"):
			solids += 1
	var tri := positions.size() / 3
	if tri == 0:
		return _fail("В файле STL нет треугольников.")
	positions.resize(tri * 3)
	var indices := PackedInt32Array()
	indices.resize(tri * 3)
	for i in indices.size():
		indices[i] = i
	return _stl_result(positions, indices, maxi(solids, 1), "STL (текстовый)")


static func _stl_result(positions: PackedVector3Array, indices: PackedInt32Array, objects: int, fmt: String) -> Dictionary:
	var tri_mat := PackedInt32Array()
	tri_mat.resize(indices.size() / 3)
	tri_mat.fill(0)
	return {
		"ok": true, "format": fmt,
		"positions": positions, "indices": indices, "tri_mat": tri_mat,
		"materials": [{"name": "не задан в STL", "color": PALETTE[0], "from_file": false}],
		"objects": objects, "skipped_refs": 0,
	}


# ---------------------------------------------------------------- пример

## Тор в миллиметрах (R = 20, r = 8) — модель для первого запуска.
static func make_sample_torus() -> Dictionary:
	var R := 20.0
	var r := 8.0
	var seg_u := 96
	var seg_v := 32
	var lines := PackedStringArray(["o Тор", "usemtl Пример"])
	for i in seg_u:
		var u := TAU * i / seg_u
		for j in seg_v:
			var v := TAU * j / seg_v
			var x := (R + r * cos(v)) * cos(u)
			var y := r * sin(v)
			var z := (R + r * cos(v)) * sin(u)
			lines.append("v %f %f %f" % [x, y, z])
	for i in seg_u:
		for j in seg_v:
			var a := i * seg_v + j + 1
			var b := ((i + 1) % seg_u) * seg_v + j + 1
			var c := ((i + 1) % seg_u) * seg_v + (j + 1) % seg_v + 1
			var d := i * seg_v + (j + 1) % seg_v + 1
			lines.append("f %d %d %d %d" % [a, d, c, b])
	var res := parse_obj("\n".join(lines))
	res["format"] = "OBJ (пример)"
	return res
