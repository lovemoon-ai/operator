# MemWorld Ultra Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live Quest demo default to the measured fastest gear: 5 inference steps, CFG 1.0, and 7 fps output playback.

**Architecture:** Keep the existing 24 Hz pose capture and 33-frame chunk protocol unchanged. Change only the inference and playback defaults at the two existing owners, verify their values propagate in the Operator-to-MemWorld session start message, and update the operating guide.

**Tech Stack:** Python 3.10, unittest, asyncio/websockets, Bash

---

### Task 1: Lock the defaults with failing tests

**Files:**
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/tests/test_live_session.py`
- Modify: `/home/evophys/code/operator/server/tests/test_memworld_gateway.py`
- Modify: `/home/evophys/code/operator/server/tests/test_memworld_e2e.py`

- [ ] **Step 1: Change the expected MemWorld default**

```python
self.assertEqual(config.num_inference_steps, 5)
self.assertEqual(config.cfg_scale, 1.0)
```

- [ ] **Step 2: Change the expected Operator defaults and session payload**

```python
self.assertEqual(memworld_gateway.PLAYBACK_FPS, 7.0)
self.assertEqual(args.num_inference_steps, 5)
self.assertEqual(start["playback_fps"], 7.0)
self.assertEqual(start["num_inference_steps"], 5)
```

- [ ] **Step 3: Run the focused tests and confirm they fail on the old 10-step/1.5-fps defaults**

```bash
cd /home/evophys/code/MemWorld
conda run -n memworld python -m unittest deploy.egoquest_ws.tests.test_live_session.LiveSessionTests.test_live_request_uses_high_speed_defaults -v
cd /home/evophys/code/operator
server/.venv/bin/python -m unittest server.tests.test_memworld_gateway.MemWorldGatewayTests.test_model_clock_and_session_use_24_hz server.tests.test_memworld_e2e.MemWorldEndToEndTests.test_gateway_uses_high_speed_inference_defaults -v
```

Expected: assertions show 10 instead of 5 and 1.5 instead of 7.0.

### Task 2: Implement the ultra defaults

**Files:**
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/raw_input_adapter.py`
- Modify: `/home/evophys/code/operator/server/memworld_gateway.py`

- [ ] **Step 1: Change the MemWorld request default**

```python
num_inference_steps: int = 5
cfg_scale: float = 1.0
```

- [ ] **Step 2: Change the Operator playback and request defaults**

```python
PLAYBACK_FPS = 7.0
parser.add_argument("--num-inference-steps", type=int, default=5)
```

- [ ] **Step 3: Run focused tests and confirm they pass**

Run the commands from Task 1 and expect all tests to pass.

### Task 3: Update documentation and verify both repositories

**Files:**
- Modify: `/home/evophys/code/operator/docs/tutorials/quest-memworld-live-demo.md`

- [ ] **Step 1: Document the selected gear**

```text
极速档：5 steps / CFG 1.0 / 7 fps playback
33 / 7 = 4.714 seconds per displayed chunk
Measured median generation time: 4.659 seconds per 33-frame chunk
```

- [ ] **Step 2: Run complete test suites**

```bash
cd /home/evophys/code/MemWorld
conda run -n memworld python -m unittest discover -s deploy/egoquest_ws/tests -v
cd /home/evophys/code/operator
server/.venv/bin/python -m unittest discover -s server/tests -v
bash -n run_memworld_worker.sh run_quest_memworld.sh
```

Expected: 22 MemWorld tests, 45 Operator tests, and Bash syntax validation all pass.

- [ ] **Step 3: Inspect the final diff without staging or committing**

```bash
git -C /home/evophys/code/MemWorld diff --check
git -C /home/evophys/code/operator diff --check
```

Per user instruction, leave all MemWorld and Operator changes local and uncommitted.
