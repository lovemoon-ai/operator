"""Run a robot-authored Blueprint without connecting a physical robot."""

from __future__ import annotations

import time

from pyoperator import (
    BlueprintComponent,
    BlueprintTransform,
    Blueprint,
    XrSession,
)

INSTRUCTION = "Open your left palm and touch the menu with the other hand."


def build_blueprint() -> Blueprint:
    return Blueprint(
        blueprint_id="example.blueprint_demo",
        components=(
            BlueprintComponent.label(
                "message",
                anchor="head",
                transform=BlueprintTransform(position=(0.0, -0.15, -0.65)),
                text_binding="demo.message",
                properties={"settings_label": "Demo message", "font_size": 30},
            ),
            BlueprintComponent.status_lamp(
                "status",
                text="Blueprint demo",
                anchor="right_controller",
                state_binding="demo.status",
                properties={"settings_label": "Demo status"},
            ),
            BlueprintComponent.palm_menu(
                "hand_toggle",
                title="Blueprint demo",
                action="toggle_demo",
                value_binding="demo.enabled",
                available_binding="demo.available",
                locked_text="Enable demo",
                unlocked_text="Disable demo",
                properties={"settings_label": "Demo palm menu"},
            ),
            BlueprintComponent.video_panel(
                properties={"settings_label": "First-person video"},
            ),
            BlueprintComponent.controller_help(
                properties={"settings_label": "Controller help"},
            ),
            BlueprintComponent.control_frame(
                properties={"settings_label": "Control frame"},
            ),
            BlueprintComponent.operation_trajectory(
                properties={"settings_label": "Operation trajectory"},
            ),
        ),
    )


def main() -> None:
    enabled = False
    started = time.monotonic()
    last_elapsed_second = -1

    with XrSession() as session:
        blueprint = session.blueprint
        blueprint.set_blueprint(build_blueprint())
        blueprint.update(
            {
                "demo.message": INSTRUCTION,
                "demo.status": "active",
                "demo.enabled": enabled,
                "demo.available": True,
            }
        )
        print("blueprint demo running; press Ctrl-C to stop")
        try:
            while session.is_running:
                event = blueprint.poll_event(timeout=0.25)
                if (
                    event is not None
                    and event.component_id == "hand_toggle"
                    and event.action == "toggle_demo"
                ):
                    enabled = bool(event.value)
                    blueprint.update(
                        {
                            "demo.enabled": enabled,
                            "demo.status": "active" if enabled else "warning",
                        }
                    )
                    print("demo enabled:", enabled)

                elapsed_second = int(time.monotonic() - started)
                if elapsed_second != last_elapsed_second:
                    last_elapsed_second = elapsed_second
                    blueprint.update(
                        {"demo.message": f"{INSTRUCTION} · {elapsed_second}s"}
                    )
        except KeyboardInterrupt:
            print("stopping blueprint demo")
        finally:
            blueprint.clear()


if __name__ == "__main__":
    main()
