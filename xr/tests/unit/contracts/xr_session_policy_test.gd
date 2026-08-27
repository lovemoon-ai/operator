extends RefCounted
## Locks the XR safety-boundary policy contract: the policy always requests the
## hidden state, and it must be able to tell "this platform has no boundary API
## and needs none" (Quest, where the guardian is removed by the
## com.oculus.feature.BOUNDARYLESS_APP manifest feature) from "the call failed".
## Collapsing those two made the app warn on every re-don about an API that was
## never missing.

const CASE_ID := "contracts.xr_session_policy"
const XRSessionPolicyScript := preload("res://scripts/xr/xr_session_policy.gd")
const PlatformRegistryScript := preload("res://scripts/platform/registry/platform_registry.gd")


class StubRegistry:
	extends RefCounted

	var calls: Array[bool] = []
	var status: int = 0
	var detail: String = "stub"

	func _init(p_status: int, p_detail: String = "stub") -> void:
		status = p_status
		detail = p_detail

	func apply_boundary_policy(visible: bool) -> Dictionary:
		calls.append(visible)
		return {"status": status, "detail": detail}


class RegistryWithoutPolicy:
	extends RefCounted


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var applied := StubRegistry.new(PlatformRegistryScript.BOUNDARY_APPLIED)
	var applied_result := XRSessionPolicyScript.apply_policy(applied)
	t.eq(applied_result.get("status"), PlatformRegistryScript.BOUNDARY_APPLIED,
		"a registry that applied the policy must be reported as applied")
	t.eq(applied.calls, [false], "boundary policy must always request the hidden state")

	var not_applicable := StubRegistry.new(
		PlatformRegistryScript.BOUNDARY_NOT_APPLICABLE, "quest: BOUNDARYLESS_APP")
	var not_applicable_result := XRSessionPolicyScript.apply_policy(not_applicable)
	t.eq(not_applicable_result.get("status"), PlatformRegistryScript.BOUNDARY_NOT_APPLICABLE,
		"a platform without a boundary API must not be reported as a failure")
	t.ne(not_applicable_result.get("status"), PlatformRegistryScript.BOUNDARY_FAILED,
		"'not applicable' must stay distinguishable from 'failed'")
	t.eq(not_applicable.calls, [false], "boundary policy must always request the hidden state")

	t.eq(
		XRSessionPolicyScript.apply_policy(
			StubRegistry.new(PlatformRegistryScript.BOUNDARY_FAILED)).get("status"),
		PlatformRegistryScript.BOUNDARY_FAILED,
		"a genuine failure must be reported as failed")
	t.eq(
		XRSessionPolicyScript.apply_policy(
			StubRegistry.new(PlatformRegistryScript.BOUNDARY_PARTIAL)).get("status"),
		PlatformRegistryScript.BOUNDARY_PARTIAL,
		"a partially applied boundary policy must not be reported as fully applied")

	t.eq(XRSessionPolicyScript.apply_policy(null).get("status"),
		PlatformRegistryScript.BOUNDARY_FAILED,
		"a missing platform registry must fail safely")
	t.eq(XRSessionPolicyScript.apply_policy(RegistryWithoutPolicy.new()).get("status"),
		PlatformRegistryScript.BOUNDARY_FAILED,
		"a registry without the boundary policy method must fail safely")

	# The four outcomes must stay distinct values, otherwise the log-level
	# routing in _apply_boundary_policy collapses again.
	var statuses := [
		PlatformRegistryScript.BOUNDARY_NOT_APPLICABLE,
		PlatformRegistryScript.BOUNDARY_APPLIED,
		PlatformRegistryScript.BOUNDARY_PARTIAL,
		PlatformRegistryScript.BOUNDARY_FAILED,
	]
	var seen := {}
	for status in statuses:
		seen[status] = true
	t.eq(seen.size(), statuses.size(), "boundary status codes must be mutually exclusive")

	# The real registry has to speak the same contract as the stubs above.
	var registry: Object = PlatformRegistryScript.create()
	t.is_true(registry.has_method("apply_boundary_policy"),
		"the platform registry must expose the boundary policy entry point")
	var live_result: Dictionary = registry.apply_boundary_policy(false)
	t.contains(live_result, "status", "the registry boundary result must carry a status")
	t.contains(statuses, live_result.get("status"),
		"the registry must report one of the declared boundary status codes")
	t.is_false(str(live_result.get("detail", "")).is_empty(),
		"the registry boundary result must explain itself for the log line")

	t.is_true(
		ProjectSettings.has_setting("autoload/XRSessionPolicy"),
		"boundary policy must be registered globally for every XR mode"
	)
