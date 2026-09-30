@tool
extends EditorPlugin

var run_button: Button

func _enter_tree() -> void:
	run_button = Button.new()
	run_button.text = "Run Tests"
	
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, run_button)
	
	var toolbar_parent = run_button.get_parent()
	if toolbar_parent:
		toolbar_parent.move_child(run_button, 5)
	
	run_button.pressed.connect(_launch_external_test_bench)

func _exit_tree() -> void:
	if run_button:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, run_button)
		run_button.queue_free()

func _launch_external_test_bench() -> void:
	EditorInterface.save_all_scenes()
	
	var godot_path = OS.get_executable_path()
	var project_path = ProjectSettings.globalize_path("res://")
	
	var args = [
		"/c",
		"start",
		"Ant Simulator Testing",
		"cmd.exe",
		"/k",
		godot_path,
		"--path", project_path, 
		"res://main.tscn",
		"--",
		"testing"
	]
	
	print("Launching external test bench...")
	
	var pid = OS.create_process("cmd.exe", args)
	
	if pid <= 0:
		printerr("Failed to launch test bench")
