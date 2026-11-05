extends SceneTree
## Проверка загрузчиков и расчётов на моделях с известным ответом.
## Запуск: Godot --headless --path . -s res://tests/run_tests.gd

var failures := 0


func _init() -> void:
	_test_obj_cube()
	_test_stl_binary()
	_test_stl_ascii()
	_test_open_mesh()
	_test_torus()
	_test_estimate()
	print("ГОТОВО: ошибок ", failures)
	quit(1 if failures > 0 else 0)


func check(name: String, got: float, want: float, tol: float) -> void:
	var ok := absf(got - want) <= tol
	if not ok:
		failures += 1
	print("%s %s: %s (ожидалось %s)" % ["OK  " if ok else "FAIL", name, got, want])


const CUBE_OBJ := """
mtllib none.mtl
o Куб
v 0 0 0
v 10 0 0
v 10 10 0
v 0 10 0
v 0 0 20
v 10 0 20
v 10 10 20
v 0 10 20
usemtl Красный
f 1 4 3 2
f 5 6 7 8
usemtl Синий
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
"""


func _test_obj_cube() -> void:
	var r := MeshLoader.parse_obj(CUBE_OBJ)
	var a := MeshAnalyzer.analyze(r.positions, r.indices, r.tri_mat, r.materials.size())
	check("OBJ куб: объём", a.volume, 2000.0, 0.01)
	check("OBJ куб: площадь", a.area, 1000.0, 0.01)
	check("OBJ куб: высота", a.aabb.size.z, 20.0, 0.0001)
	check("OBJ куб: треугольники", a.triangles, 12, 0)
	check("OBJ куб: замкнут", 1.0 if a.closed else 0.0, 1.0, 0)
	check("OBJ куб: материалов", r.materials.size(), 2, 0)
	check("OBJ куб: треуг. у Синего", a.mat_tris[1], 8, 0)
	check("OBJ куб: нормали наружу", 0.0 if a.inverted else 1.0, 1.0, 0)


func _cube_tris() -> Array:
	var r := MeshLoader.parse_obj(CUBE_OBJ)
	var tris := []
	for i in r.indices.size():
		tris.append(r.positions[r.indices[i]])
	return tris


func _test_stl_binary() -> void:
	var tris := _cube_tris()
	var b := PackedByteArray()
	b.resize(84 + tris.size() / 3 * 50)
	b.fill(0)
	# заголовок начинается со «solid», чтобы проверить, что бинарный файл не путается с текстовым
	for i in 5:
		b[i] = "solid".unicode_at(i)
	b.encode_u32(80, tris.size() / 3)
	for t in tris.size() / 3:
		for j in 3:
			var p: Vector3 = tris[t * 3 + j]
			var o := 84 + t * 50 + 12 + j * 12
			b.encode_float(o, p.x)
			b.encode_float(o + 4, p.y)
			b.encode_float(o + 8, p.z)
	var r := MeshLoader.parse_stl(b)
	var a := MeshAnalyzer.analyze(r.positions, r.indices, r.tri_mat, 1)
	check("STL бинарный: объём", a.volume, 2000.0, 0.01)
	check("STL бинарный: замкнут после сшивки", 1.0 if a.closed else 0.0, 1.0, 0)
	check("STL бинарный: вершины после сшивки", a.vertices, 8, 0)


func _test_stl_ascii() -> void:
	var tris := _cube_tris()
	var lines := PackedStringArray(["solid cube"])
	for t in tris.size() / 3:
		lines.append("facet normal 0 0 0\nouter loop")
		for j in 3:
			var p: Vector3 = tris[t * 3 + j]
			lines.append("vertex %f %f %f" % [p.x, p.y, p.z])
		lines.append("endloop\nendfacet")
	lines.append("endsolid cube")
	var r := MeshLoader.parse_stl("\n".join(lines).to_ascii_buffer())
	var a := MeshAnalyzer.analyze(r.positions, r.indices, r.tri_mat, 1)
	check("STL текстовый: объём", a.volume, 2000.0, 0.01)
	check("STL текстовый: формат", 1.0 if r.format == "STL (текстовый)" else 0.0, 1.0, 0)


func _test_open_mesh() -> void:
	var r := MeshLoader.parse_obj(CUBE_OBJ.replace("f 5 6 7 8\n", ""))
	var a := MeshAnalyzer.analyze(r.positions, r.indices, r.tri_mat, r.materials.size())
	check("Куб без крышки: не замкнут", 1.0 if a.closed else 0.0, 0.0, 0)
	check("Куб без крышки: открытых рёбер", a.open_edges, 4, 0)


func _test_torus() -> void:
	var r := MeshLoader.make_sample_torus()
	var a := MeshAnalyzer.analyze(r.positions, r.indices, r.tri_mat, r.materials.size())
	var exact := 2.0 * PI * PI * 20.0 * 64.0
	check("Тор: объём ≈ 2π²Rr² (−1 % на гранях)", a.volume, exact, exact * 0.01)
	check("Тор: замкнут", 1.0 if a.closed else 0.0, 1.0, 0)
	check("Тор: нормали наружу", 0.0 if a.inverted else 1.0, 1.0, 0)
	check("Тор: ширина", a.aabb.size.x, 56.0, 0.01)


func _test_estimate() -> void:
	# Куб 20 мм: V = 8000 мм³, S = 2400 мм², оболочка 1,2 мм -> 2880 мм³, внутри 5120 × 20 % = 1024
	var e := PrintEstimate.compute(8000.0, 2400.0, 1.24, 1.75, 20.0, 1.2, 0.0, 25.0)
	check("Оценка: объём пластика", e.printed_mm3, 3904.0, 0.01)
	check("Оценка: масса PLA", e.grams, 4.84096, 0.0001)
	check("Оценка: длина нити 1,75", e.length_m, 3904.0 / (PI * 0.875 * 0.875) / 1000.0, 0.0001)
