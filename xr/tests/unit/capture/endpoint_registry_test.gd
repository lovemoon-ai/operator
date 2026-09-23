extends RefCounted
## EndpointRegistry: hosts reference locally verified ingest endpoints by
## name only.

const CASE_ID := "capture.endpoint_registry"
const TEST_PATH := "user://test_ingest_endpoints.cfg"


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	t.is_true(EndpointRegistry.is_valid_name("lab-ingest"), "a bare name is a valid endpoint_ref")
	for invalid in ["", "https://lab/ingest", "lab/ingest", "10.0.0.2:8443"]:
		t.is_false(EndpointRegistry.is_valid_name(invalid), "%s is not a valid endpoint_ref" % invalid)
	t.eq(EndpointRegistry.host_of_url("https://user@lab.local:8443/api/ingest?x=1"), "lab.local",
		"host_of_url drops scheme, userinfo, port and path")
	t.eq(EndpointRegistry.name_for_host("[fe80::1]"), "fe80--1", "IPv6 hosts become bare names")

	var registry := EndpointRegistry.new(TEST_PATH)
	var upload := registry.register_upload("https://lab.local:8443/api/ingest", "secret", true)
	t.eq(upload, "lab.local", "an upload endpoint is named after its host")
	var unverified := registry.register_upload("http://10.0.0.9/ingest", "", false, "scratch")
	t.eq(unverified, "scratch", "an explicit valid name wins")
	var live := registry.register_live("10.0.0.2", 63910, 63912, "tok", true)
	t.eq(registry.resolve(upload, EndpointRegistry.KIND_UPLOAD).get("token"), "secret",
		"a verified upload endpoint resolves")
	t.is_true(registry.resolve("scratch").is_empty(), "an unverified endpoint never resolves")
	t.is_true(registry.resolve(live, EndpointRegistry.KIND_UPLOAD).is_empty(),
		"an endpoint of another kind does not resolve")
	t.is_true(registry.resolve("unknown").is_empty(), "an unknown name does not resolve")

	var reloaded := EndpointRegistry.new(TEST_PATH)
	reloaded.load_from_disk()
	t.eq(reloaded.names(), ["10.0.0.2", "lab.local", "scratch"], "endpoints persist across instances")
	reloaded.forget("scratch")
	t.eq(reloaded.names(EndpointRegistry.KIND_UPLOAD), ["lab.local"], "forget removes an endpoint")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
