// Host math conformance against the real deployment header (no robot/runtime).
#include <array>
#include <vector>
#include <iostream>
#include <iomanip>
#include "policy_parameters.hpp"

template <typename T> void emit(const char* name, const T& values) {
    std::cout << name << ':' << std::setprecision(17);
    for (auto value : values) std::cout << value << ' ';
    std::cout << '\n';
}
int main() {
    emit("default_angles", default_angles);
    emit("kps", kps);
    emit("kds", kds);
    emit("g1_action_scale", g1_action_scale);
    emit("isaaclab_to_mujoco", isaaclab_to_mujoco);
    emit("mujoco_to_isaaclab", mujoco_to_isaaclab);
}
