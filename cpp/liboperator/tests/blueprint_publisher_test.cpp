#include <cassert>
#include <cstdint>
#include <string>

#include <operator/operator.hpp>

int main() {
  operator_sdk::BlueprintPublisher publisher;
  assert(operator_sdk::BlueprintPublisher::spec_version() == 1);
  assert(operator_sdk::BlueprintPublisher::spec_sha256().size() == 64);
  assert(publisher
             .descriptor_message_json(
                 R"({"device":{"type":"test","name":"Test"},"control_schema":{}})")
             .find(R"("blueprint_v1":true)") != std::string::npos);

  publisher.set_blueprint_json(
      R"({"schema":"operator.blueprint.v1","blueprint_id":"cpp.test","revision":1,"components":[{"id":"status","type":"status_lamp","bindings":{"state":"status"}}]})");
  assert(publisher.update_values_json(R"({"status":"active"})", 10) == 1);

  bool rejected = false;
  try {
    publisher.update_values_json(R"({"unknown":true})", 11);
  } catch (const operator_sdk::Error&) {
    rejected = true;
  }
  assert(rejected);
  assert(publisher.update_values_json(R"({"status":"idle"})", 12) == 2);
  assert(publisher.state_message_json().find(R"("status":"idle")") !=
         std::string::npos);

  publisher.clear();
  rejected = false;
  try {
    publisher.definition_message_json();
  } catch (const operator_sdk::Error&) {
    rejected = true;
  }
  assert(rejected);
}
