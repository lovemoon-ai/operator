class_name MjResetPolicy
extends RefCounted


static func apply(simulation: MjSimulation, scenario: MjScenario) -> Dictionary:
	if simulation == null:
		return {"ok": false, "error": "missing simulation"}
	var seed := scenario.seed if scenario else 0
	simulation.reset(seed)
	var metadata := scenario.instantiate_metadata() if scenario else {"seed": seed}
	metadata["reset_usec"] = Time.get_ticks_usec()
	metadata["simulation_backend"] = simulation.get_backend_name()
	metadata["native_status"] = simulation.get_native_status()
	return {"ok": true, "metadata": metadata}
