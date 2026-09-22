"""Argument parsing, prompt library sources, terminal prompt input, and batch mode."""
import io
from types import SimpleNamespace

import numpy as np
import pytest

from light_o1_vr.app import StdinPrompts, make_generator, parse_args, prompt_library, run_batch
from light_o1_vr.generator import ControlServerClient, FileGenerator, GpuApiClient
from light_o1_vr.prompts import DEFAULT_PROMPTS, PromptLibrary, clean_prompts, load_prompts
from light_o1_vr.rollout import SETTLE_TICKS, Trajectory
from fakes import FakeGenerator, FakeLightO1, FakeSimulator


def test_parse_args_defaults_and_generator_urls():
    args = parse_args([])
    assert args.generator == "control" and args.url == "http://127.0.0.1:8090"
    assert args.replan_frames == 8 and args.lookahead_frames == 12 and args.thinking and args.face_user
    assert args.asset_port == 63904 and args.distance == 2.5 and args.stdin and args.batch is None
    assert parse_args(["--generator", "api"]).url == "http://127.0.0.1:8030"
    assert parse_args(["--url", "http://gpu:8090/"]).url == "http://gpu:8090/"
    assert parse_args(["--generator", "file", "--actions-dir", "/tmp"]).url is None
    args = parse_args(["--no-thinking", "--no-face-user", "--no-stdin", "--headset-ip", "10.0.0.2",
                       "--headset-ip", "10.0.0.3", "--batch", "wave", "--output", "t.npz"])
    assert not args.thinking and not args.face_user and not args.stdin
    assert args.headset_ip == ["10.0.0.2", "10.0.0.3"] and args.batch == "wave" and str(args.output) == "t.npz"


@pytest.mark.parametrize("argv", [
    ["--generator", "file"],
    ["--url", "gpu:8090"],
    ["--asset-port", "0"],
    ["--distance", "0"],
    ["--prebuffer", "-1"],
    ["--seed", "-3"],
    ["--output", "t.npz"],
    ["--replan-frames", "0"],
])
def test_parse_args_rejects_invalid_values(argv):
    with pytest.raises(SystemExit):
        parse_args(argv)


def test_make_generator_selects_the_requested_client(tmp_path):
    assert isinstance(make_generator(parse_args([])), ControlServerClient)
    assert isinstance(make_generator(parse_args(["--generator", "api"])), GpuApiClient)
    np.save(tmp_path / "wave.npy", np.zeros((2, 138), np.float32))
    generator = make_generator(parse_args(["--generator", "file", "--actions-dir", str(tmp_path)]))
    assert isinstance(generator, FileGenerator)
    assert prompt_library(parse_args(["--generator", "file", "--actions-dir", str(tmp_path)]), generator) == ["wave"]
    assert prompt_library(parse_args([]), ControlServerClient()) == list(DEFAULT_PROMPTS)
    (tmp_path / "prompts.txt").write_text("# comment\n\n  bow  politely \nwave\nWave\n")
    assert prompt_library(parse_args(["--prompts", str(tmp_path / "prompts.txt")]), None) == ["bow politely", "wave"]
    (tmp_path / "empty.txt").write_text("# nothing\n")
    with pytest.raises(ValueError):
        load_prompts(tmp_path / "empty.txt")


def test_prompt_library_cycles_and_selects():
    assert clean_prompts(["  a  b ", "A B", "", "c"]) == ["a b", "c"]
    library = PromptLibrary(["wave", "walk"])
    assert len(library) == 2 and library.current == "wave"
    assert library.next() == "walk" and library.next() == "wave" and library.prev() == "walk"
    assert library.select("WALK") == "walk" and library.index == 1 and len(library) == 2
    assert library.select(" jump  high ") == "jump high" and library.index == 2 and list(library)[-1] == "jump high"
    with pytest.raises(ValueError):
        library.select("  ")
    with pytest.raises(ValueError):
        PromptLibrary([" "])


def test_stdin_prompts_forward_non_empty_lines_until_eof():
    typed = StdinPrompts(io.StringIO("wave hello\n\n   \n  do a squat  \n"))
    typed.start()
    typed.join(2.0)
    assert not typed.is_alive()
    assert typed.drain() == ["wave hello", "do a squat"]
    assert typed.drain() == []


def test_run_batch_generates_simulates_and_saves(tmp_path, capsys):
    args = parse_args(["--batch", "wave", "--output", str(tmp_path / "wave.npz"), "--seed", "2"])
    generator = FakeGenerator(frames=4)
    trajectory = run_batch(args, FakeLightO1(), FakeSimulator(), generator)
    assert generator.calls == [("wave", 2, True)]
    assert trajectory.ok and len(trajectory) == SETTLE_TICKS + 10
    saved = Trajectory.load(tmp_path / "wave.npz")
    assert saved.prompt == "wave" and len(saved) == len(trajectory)
    out = capsys.readouterr().out
    assert '"frames": 85' in out and '"fell_at": null' in out and "fake reasoning" in out


def test_run_batch_fails_loudly_when_the_rollout_breaks():
    class Broken(FakeSimulator):
        def warmup(self):
            raise RuntimeError("no policy")

    args = parse_args(["--batch", "wave"])
    with pytest.raises(SystemExit, match="no policy"):
        run_batch(args, FakeLightO1(), Broken(), FakeGenerator(frames=4))
