#!/usr/bin/env python

# Copyright 2026 NVIDIA Corporation and The HuggingFace Inc. team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Record Operator XR -> real SO-101 episodes as a LeRobotDataset."""

import logging
import sys
import time
from dataclasses import asdict, dataclass, field
from pprint import pformat

from lerobot.cameras import CameraConfig  # noqa: F401
from lerobot.cameras.opencv import OpenCVCameraConfig  # noqa: F401
from lerobot.common.control_utils import sanity_check_dataset_robot_compatibility
from lerobot.configs import parser
from lerobot.configs.dataset import DatasetRecordConfig
from lerobot.datasets import (
    LeRobotDataset,
    VideoEncodingManager,
    aggregate_pipeline_dataset_features,
    create_initial_features,
    safe_stop_image_writer,
)
from lerobot.processor import make_default_processors
from lerobot.robots import RobotConfig
from lerobot.robots.so_follower import SOFollowerConfig  # noqa: F401
from lerobot.utils.constants import ACTION, OBS_STR
from lerobot.utils.feature_utils import build_dataset_frame, combine_feature_dicts
from lerobot.utils.robot_utils import precise_sleep
from lerobot.utils.utils import init_logging

from .common import (
    RESET_DURATION_S,
    Device,
    HoldLatch,
    build_device,
    init_keyboard_listener,
)
from .config import OperatorControllerConfig
from .operator_source import OPERATOR_DATASET_FEATURES, OperatorKillRequested


@dataclass
class RecordConfig:
    robot: RobotConfig
    dataset: DatasetRecordConfig
    teleop: OperatorControllerConfig = field(default_factory=OperatorControllerConfig)
    reset_to_origin: bool = True
    reset_duration: float = RESET_DURATION_S
    resume: bool = False


@safe_stop_image_writer
def _record_loop(
    robot,
    device: Device,
    motor_names: list[str],
    events: dict,
    fps: int,
    dataset: LeRobotDataset | None = None,
    control_time_s: float = 0.0,
    single_task: str | None = None,
) -> None:
    interval_s = 1.0 / fps
    started = time.perf_counter()
    hold = HoldLatch(motor_names)

    while time.perf_counter() - started < control_time_s:
        loop_started = time.perf_counter()
        if events["exit_early"]:
            events["exit_early"] = False
            break

        observation = robot.get_observation()
        target_action = hold.resolve(device.compute(observation), observation)
        # LeRobot may clip this target through max_relative_target. Record the
        # action actually sent so dataset action matches physical execution.
        sent_action = robot.send_action(target_action)

        if dataset is not None:
            observation_frame = build_dataset_frame(dataset.features, observation, prefix=OBS_STR)
            action_frame = build_dataset_frame(dataset.features, sent_action, prefix=ACTION)
            dataset.add_frame(
                {
                    **observation_frame,
                    **device.last_frame().dataset_frame(),
                    **action_frame,
                    "task": single_task,
                }
            )

        precise_sleep(max(interval_s - (time.perf_counter() - loop_started), 0.0))


def _dataset_features(robot, *, use_videos: bool) -> dict[str, dict]:
    teleop_processor, _, observation_processor = make_default_processors()
    features = combine_feature_dicts(
        aggregate_pipeline_dataset_features(
            pipeline=teleop_processor,
            initial_features=create_initial_features(action=robot.action_features),
            use_videos=use_videos,
        ),
        aggregate_pipeline_dataset_features(
            pipeline=observation_processor,
            initial_features=create_initial_features(observation=robot.observation_features),
            use_videos=use_videos,
        ),
    )
    features.update(OPERATOR_DATASET_FEATURES)
    return features


@parser.wrap()
def record(cfg: RecordConfig) -> LeRobotDataset:
    init_logging()
    logging.info(pformat(asdict(cfg)))
    if cfg.resume and cfg.dataset.root is None:
        raise ValueError("--dataset.root is required with --resume=true")
    if cfg.dataset.fps <= 0 or cfg.dataset.episode_time_s <= 0:
        raise ValueError("--dataset.fps and --dataset.episode_time_s must be positive")
    if cfg.dataset.num_episodes <= 0:
        raise ValueError("--dataset.num_episodes must be positive")

    robot, device, motor_names = build_device(cfg)
    dataset: LeRobotDataset | None = None
    listener = None
    try:
        features = _dataset_features(robot, use_videos=cfg.dataset.video)
        num_cameras = len(robot.cameras) if hasattr(robot, "cameras") else 0
        image_writer_threads = cfg.dataset.num_image_writer_threads_per_camera * num_cameras

        if cfg.resume:
            dataset = LeRobotDataset.resume(
                cfg.dataset.repo_id,
                root=cfg.dataset.root,
                batch_encoding_size=cfg.dataset.video_encoding_batch_size,
                rgb_encoder=cfg.dataset.rgb_encoder,
                depth_encoder=cfg.dataset.depth_encoder,
                encoder_threads=cfg.dataset.encoder_threads,
                streaming_encoding=cfg.dataset.streaming_encoding,
                encoder_queue_maxsize=cfg.dataset.encoder_queue_maxsize,
                image_writer_processes=(
                    cfg.dataset.num_image_writer_processes if num_cameras > 0 else 0
                ),
                image_writer_threads=image_writer_threads if num_cameras > 0 else 0,
            )
            sanity_check_dataset_robot_compatibility(dataset, robot, cfg.dataset.fps, features)
        else:
            cfg.dataset.stamp_repo_id()
            dataset = LeRobotDataset.create(
                cfg.dataset.repo_id,
                cfg.dataset.fps,
                root=cfg.dataset.root,
                robot_type=robot.name,
                features=features,
                use_videos=cfg.dataset.video,
                image_writer_processes=cfg.dataset.num_image_writer_processes,
                image_writer_threads=image_writer_threads,
                batch_encoding_size=cfg.dataset.video_encoding_batch_size,
                rgb_encoder=cfg.dataset.rgb_encoder,
                depth_encoder=cfg.dataset.depth_encoder,
                encoder_threads=cfg.dataset.encoder_threads,
                streaming_encoding=cfg.dataset.streaming_encoding,
                encoder_queue_maxsize=cfg.dataset.encoder_queue_maxsize,
            )

        listener, events = init_keyboard_listener()
        loop_kwargs = {
            "robot": robot,
            "device": device,
            "motor_names": motor_names,
            "events": events,
            "fps": cfg.dataset.fps,
            "single_task": cfg.dataset.single_task,
        }

        try:
            with VideoEncodingManager(dataset):
                recorded_episodes = 0
                while recorded_episodes < cfg.dataset.num_episodes and not events["stop_recording"]:
                    logging.info("Recording episode %d", dataset.num_episodes)
                    _record_loop(
                        **loop_kwargs,
                        dataset=dataset,
                        control_time_s=cfg.dataset.episode_time_s,
                    )

                    if not dataset.has_pending_frames():
                        events["rerecord_episode"] = False
                        if events["stop_recording"]:
                            break
                        logging.warning("Episode ended before its first frame; retrying")
                        continue

                    if not events["stop_recording"] and (
                        recorded_episodes < cfg.dataset.num_episodes - 1
                        or events["rerecord_episode"]
                    ):
                        logging.info("Reset the environment")
                        _record_loop(
                            **loop_kwargs,
                            dataset=None,
                            control_time_s=cfg.dataset.reset_time_s,
                        )

                    if events["rerecord_episode"]:
                        events["rerecord_episode"] = False
                        events["exit_early"] = False
                        dataset.clear_episode_buffer()
                        continue

                    dataset.save_episode()
                    recorded_episodes += 1
        except OperatorKillRequested as exc:
            logging.warning("Operator stop: %s; discarding the current partial episode", exc)
            dataset.clear_episode_buffer()

    finally:
        primary_error_active = sys.exc_info()[0] is not None
        logging.info("Stop recording")
        try:
            device.cleanup()
        except Exception:
            logging.exception("Operator input cleanup failed")
        try:
            if robot.is_connected:
                robot.disconnect()
        except Exception:
            logging.exception("Follower disconnect failed")
        if listener is not None:
            try:
                listener.stop()
            except Exception:
                logging.exception("Keyboard listener cleanup failed")
        if dataset is not None:
            try:
                dataset.finalize()
            except Exception:
                if primary_error_active:
                    logging.exception("Dataset finalize failed during exception cleanup")
                else:
                    raise
        if cfg.dataset.push_to_hub and primary_error_active:
            logging.warning("Recording failed; skipping push_to_hub")
        elif cfg.dataset.push_to_hub:
            if dataset is not None and dataset.num_episodes > 0:
                dataset.push_to_hub(tags=cfg.dataset.tags, private=cfg.dataset.private)
            else:
                logging.warning("No saved episodes; skipping push_to_hub")

    if dataset is None:
        raise RuntimeError("dataset initialization failed")
    return dataset


def main() -> None:
    record()


if __name__ == "__main__":
    main()
