class_name MeshAnalyzer
extends RefCounted
## Геометрия сетки: габариты, объём, площадь, замкнутость, материалы.
## Все величины в единицах файла; перевод в мм делает интерфейс.


static func analyze(positions: PackedVector3Array, indices: PackedInt32Array, tri_mat: PackedInt32Array, mat_count: int) -> Dictionary:
	var tri_count := indices.size() / 3

	# Габариты считаем только по вершинам, которые входят в треугольники.
	var used := PackedByteArray()
	used.resize(positions.size())
	used.fill(0)
	for i in indices:
		used[i] = 1
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in positions.size():
		if used[i]:
			lo = lo.min(positions[i])
			hi = hi.max(positions[i])
	var aabb := AABB(lo, hi - lo)
	var center := aabb.get_center()

	# Объём — сумма знаковых объёмов тетраэдров (точка отсчёта — центр, чтобы не терять точность).
	var volume := 0.0
	var area := 0.0
	var mat_tris := PackedInt32Array()
	mat_tris.resize(maxi(mat_count, 1))
	mat_tris.fill(0)
	for t in tri_count:
		var a := positions[indices[t * 3]] - center
		var b := positions[indices[t * 3 + 1]] - center
		var c := positions[indices[t * 3 + 2]] - center
		area += (b - a).cross(c - a).length() * 0.5
		volume += a.dot(b.cross(c)) / 6.0
		mat_tris[tri_mat[t]] += 1

	# Сшиваем совпадающие вершины (в STL каждая вершина записана отдельно) и считаем рёбра.
	var q := maxf(aabb.size.length() * 1e-6, 1e-9)
	var weld := PackedInt32Array()
	weld.resize(positions.size())
	var map := {}
	for i in positions.size():
		if not used[i]:
			continue
		var p := positions[i]
		var key := Vector3i(roundi(p.x / q), roundi(p.y / q), roundi(p.z / q))
		var id: int = map.get(key, -1)
		if id == -1:
			id = map.size()
			map[key] = id
		weld[i] = id
	var nverts := map.size()

	var edges := {}
	var degenerate := 0
	for t in tri_count:
		var i0 := weld[indices[t * 3]]
		var i1 := weld[indices[t * 3 + 1]]
		var i2 := weld[indices[t * 3 + 2]]
		if i0 == i1 or i1 == i2 or i0 == i2:
			degenerate += 1
			continue
		for e in [[i0, i1], [i1, i2], [i2, i0]]:
			var k: int = mini(e[0], e[1]) * nverts + maxi(e[0], e[1])
			edges[k] = edges.get(k, 0) + 1
	var open_edges := 0
	var nonmanifold := 0
	for cnt in edges.values():
		if cnt == 1:
			open_edges += 1
		elif cnt > 2:
			nonmanifold += 1

	return {
		"aabb": aabb,
		"volume": absf(volume),
		"inverted": volume < 0.0,
		"area": area,
		"triangles": tri_count,
		"vertices": nverts,
		"open_edges": open_edges,
		"nonmanifold_edges": nonmanifold,
		"degenerate": degenerate,
		"closed": open_edges == 0 and nonmanifold == 0,
		"mat_tris": mat_tris,
	}


## Массивы для ArrayMesh: по одной поверхности на материал, плоские нормали.
## Godot считает лицевой сторону с обходом по часовой стрелке, а OBJ/STL — против,
## поэтому меняем порядок вершин b и c.
static func build_surfaces(positions: PackedVector3Array, indices: PackedInt32Array, tri_mat: PackedInt32Array, mat_count: int) -> Array:
	var verts: Array[PackedVector3Array] = []
	var norms: Array[PackedVector3Array] = []
	for m in maxi(mat_count, 1):
		verts.append(PackedVector3Array())
		norms.append(PackedVector3Array())
	for t in indices.size() / 3:
		var m := tri_mat[t]
		var a := positions[indices[t * 3]]
		var b := positions[indices[t * 3 + 1]]
		var c := positions[indices[t * 3 + 2]]
		var n := (b - a).cross(c - a).normalized()
		verts[m].append(a)
		verts[m].append(c)
		verts[m].append(b)
		norms[m].append(n)
		norms[m].append(n)
		norms[m].append(n)
	var out := []
	for m in verts.size():
		out.append({"material": m, "vertices": verts[m], "normals": norms[m]})
	return out
