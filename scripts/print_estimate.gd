class_name PrintEstimate
extends RefCounted
## Приблизительный расход пластика для FDM-печати без слайсера.
##
## Модель: оболочка толщиной wall_mm (стенки + верх/низ) печатается сплошной,
## внутренность — с заполнением infill. Оболочку оцениваем как площадь × толщину,
## но не больше всего объёма (тонкие детали печатаются целиком).
## Поддержки добавляются процентом сверху.

const MATERIALS := [
	{"name": "PLA", "density": 1.24},
	{"name": "PETG", "density": 1.27},
	{"name": "ABS", "density": 1.04},
	{"name": "ASA", "density": 1.07},
	{"name": "TPU", "density": 1.21},
	{"name": "Нейлон (PA)", "density": 1.14},
	{"name": "PC", "density": 1.20},
]


## volume_mm3, area_mm2 — уже в миллиметрах.
static func compute(volume_mm3: float, area_mm2: float, density: float, diameter_mm: float,
		infill_pct: float, wall_mm: float, support_pct: float, price_per_kg: float) -> Dictionary:
	var shell := minf(volume_mm3, area_mm2 * wall_mm)
	var inner := maxf(volume_mm3 - shell, 0.0)
	var printed := (shell + inner * infill_pct / 100.0) * (1.0 + support_pct / 100.0)
	var grams := printed / 1000.0 * density
	var section := PI * pow(diameter_mm * 0.5, 2.0)
	return {
		"printed_mm3": printed,
		"grams": grams,
		"length_m": printed / section / 1000.0,
		"cost": grams / 1000.0 * price_per_kg,
		"per_kg": int(floor(1000.0 / grams)) if grams > 0.0 else 0,
	}
