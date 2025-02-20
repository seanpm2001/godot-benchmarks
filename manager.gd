extends Node

class Results:
	var render_cpu := 0.0
	var render_gpu := 0.0
	var idle := 0.0
	var physics := 0.0
	var time := 0.0

class Test:
	var name : String
	var category : String
	var path : String
	var results : Results = null
	func _init(p_name : String,p_category: String,p_path : String):
		name = p_name
		category = p_category
		path = p_path

# List of benchmarks populated in `_ready()`.
var tests: Array[Test] = []

var recording := false
var run_from_cli := false
var save_json_to_path := ""


## Returns file paths ending with `.tscn` within a folder, recursively.
func dir_contents(path: String, contents: PackedStringArray = PackedStringArray()) -> PackedStringArray:

	var dir := DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir():
				dir_contents(path.path_join(file_name), contents)
			elif file_name.ends_with(".tscn"):
				contents.push_back(path.path_join(file_name))
			file_name = dir.get_next()
	else:
		print("An error occurred when trying to access the path: %s" % path)

	return contents


func _ready():
	RenderingServer.viewport_set_measure_render_time(get_tree().root.get_viewport_rid(),true)
	set_process(false)

	# Register benchmarks automatically based on `.tscn` file paths in the `benchmarks/` folder.
	# Scene names starting with `_` are excluded, as this denotes an instanced scene that is
	# referred to in another scene.
	var benchmark_paths := dir_contents("res://benchmarks/")
	benchmark_paths.sort()
	for benchmark_path in benchmark_paths:
		var benchmark_name := benchmark_path.get_file().get_basename()
		# Capitalize only after checking whether the name begins with `_`, as `capitalize()`
		# removes underscores.
		if not benchmark_name.begins_with("_"):
			benchmark_name = benchmark_name.capitalize()
			var category := benchmark_path.get_base_dir().trim_prefix("res://benchmarks/").replace("/", " > ").capitalize()
			tests.push_back(Test.new(benchmark_name, category, benchmark_path))


func get_test_count() -> int:
	return tests.size()


func get_test_name(index: int) -> String:
	return tests[index].name


func get_test_category(index: int) -> String:
	return tests[index].category


func get_test_result(index: int) -> Results:
	return tests[index].results


func get_test_path(index: int) -> String:
	return tests[index].path


func benchmark(test_indices: Array, return_path: String) -> void:
	for i in range(test_indices.size()):
		DisplayServer.window_set_title("%d/%d - Running - Godot Benchmarks" % [i + 1, test_indices.size()])
		print("Running benchmark %d of %d: %s" % [
				i + 1, test_indices.size(),
				tests[test_indices[i]].path.trim_prefix("res://benchmarks/").trim_suffix(".tscn")
		])
		await run_test(test_indices[i])

	get_tree().change_scene_to_file(return_path)
	DisplayServer.window_set_title("[DONE] %d benchmarks - Godot Benchmarks" % test_indices.size())
	print_rich("[color=green][b]Done running %d benchmarks.[/b] Results JSON:[/color]\n" % test_indices.size())

	print("Results JSON:")
	print("----------------")
	print(JSON.stringify(get_results_dict()))
	print("----------------")

	if not save_json_to_path.is_empty():
		print("Saving JSON output to: %s" % save_json_to_path)
		var file := FileAccess.open(save_json_to_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(get_results_dict()))

	if run_from_cli:
		# Automatically exit after running benchmarks for automation purposes.
		get_tree().quit()


func run_test(index: int) -> void:
	var results := Results.new()
	var begin_time := Time.get_ticks_usec()
	set_process(true)
	recording = true

	get_tree().change_scene_to_file(tests[index].path)

	# Wait for the scene tree to be ready (required for `benchmark_config` group to be available).
	# This requires waiting for 2 frames to work consistently (1 frame is flaky).
	for i in 2:
		await get_tree().process_frame

	var benchmark_node := get_tree().get_first_node_in_group("benchmark_config")

	var record_render_cpu := true
	var record_render_gpu := true
	var record_idle := true
	var record_physics := true
	var time_limit := true

	if benchmark_node:
		record_render_cpu = benchmark_node.test_render_cpu
		record_render_gpu = benchmark_node.test_render_gpu
		record_idle = benchmark_node.test_idle
		record_physics = benchmark_node.test_physics
		time_limit = benchmark_node.time_limit

	var frames_captured := 0
	while recording:
		#Skip first frame
		await get_tree().process_frame

		if record_render_cpu:
			results.render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(get_tree().root.get_viewport_rid())  + RenderingServer.get_frame_setup_time_cpu()
		if record_render_gpu:
			results.render_gpu += RenderingServer.viewport_get_measured_render_time_gpu(get_tree().root.get_viewport_rid())
		if record_idle:
			results.idle += 0.0
		if record_physics:
			results.physics += 0.0

		frames_captured += 1

		# Some benchmarks (such as scripting) may not have a time limit.
		if time_limit:
			# Time limit of 5 seconds (5 million microseconds).
			if (Time.get_ticks_usec() - begin_time) > 5e6:
				break

	results.render_cpu /= float(max(1.0, float(frames_captured)))
	results.render_gpu /= float(max(1.0, float(frames_captured)))
	results.idle /= float(max(1.0, float(frames_captured)))
	results.physics /= float(max(1.0, float(frames_captured)))
	results.time = (Time.get_ticks_usec() - begin_time) * 0.001

	tests[index].results = results


func end_test() -> void:
	recording = false

func get_results_dict() -> Dictionary:
	var version_info := Engine.get_version_info()
	var version_string: String
	if version_info.patch >= 1:
		version_string = "v%d.%d.%d.%s.%s" % [version_info.major, version_info.minor, version_info.patch, version_info.status, version_info.build]
	else:
		version_string = "v%d.%d.%s.%s" % [version_info.major, version_info.minor, version_info.status, version_info.build]

	var engine_binary := FileAccess.open(OS.get_executable_path(), FileAccess.READ)
	var dict := {
		engine = {
			version = version_string,
			version_hash = version_info.hash,
			build_type = (
					"editor" if OS.has_feature("editor")
					else "template_debug" if OS.is_debug_build()
					else "template_release"
			),
			binary_size = engine_binary.get_length(),
		},
		system = {
			os = OS.get_name(),
			cpu_name = OS.get_processor_name(),
			cpu_architecture = (
				"x86_64" if OS.has_feature("x86_64")
				else "arm64" if OS.has_feature("arm64")
				else "arm" if OS.has_feature("arm")
				else "x86" if OS.has_feature("x86")
				else "unknown"
			),
			cpu_count = OS.get_processor_count(),
			gpu_name = RenderingServer.get_video_adapter_name(),
			gpu_vendor = RenderingServer.get_video_adapter_vendor(),
		}
	}

	var benchmarks := []
	for i in Manager.get_test_count():
		var test := {
			category = Manager.get_test_category(i),
			name = Manager.get_test_name(i),
		}

		var result: Results = Manager.get_test_result(i)
		if result:
			test.results = {
				render_cpu = snapped(result.render_cpu, 0.01),
				render_gpu = snapped(result.render_gpu, 0.01),
				idle = snapped(result.idle, 0.01),
				physics = snapped(result.physics, 0.01),
				time = round(result.time),
			}
		else:
			test.results = {}

		benchmarks.push_back(test)

	dict.benchmarks = benchmarks

	return dict
