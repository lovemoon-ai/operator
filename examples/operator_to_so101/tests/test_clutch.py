import numpy as np

from operator_to_so101.clutch import Clutch


def test_first_engage_is_jump_free_and_tracks_relative_translation() -> None:
    home = np.eye(4)
    home[:3, 3] = [0.2, -0.1, 0.3]
    clutch = Clutch(home)
    quat = np.asarray([0.0, 0.0, 0.0, 1.0])
    origin = np.asarray([1.0, 2.0, 3.0])

    clutch.engage(origin, quat, measured_base_T_ee=home)
    position, orientation = clutch.rebase(origin, quat)
    np.testing.assert_allclose(position, home[:3, 3])
    np.testing.assert_allclose(orientation, quat)

    position, _ = clutch.rebase(origin + [0.05, -0.02, 0.01], quat)
    np.testing.assert_allclose(position, home[:3, 3] + [0.05, -0.02, 0.01])


def test_reengage_latches_measured_position() -> None:
    home = np.eye(4)
    clutch = Clutch(home)
    quat = np.asarray([0.0, 0.0, 0.0, 1.0])
    clutch.engage(np.zeros(3), quat, measured_base_T_ee=home)
    clutch.rebase(np.asarray([0.1, 0.0, 0.0]), quat)

    moved = np.eye(4)
    moved[:3, 3] = [0.08, 0.02, 0.0]
    new_origin = np.asarray([4.0, 5.0, 6.0])
    clutch.engage(new_origin, quat, measured_base_T_ee=moved)
    position, _ = clutch.rebase(new_origin, quat)
    np.testing.assert_allclose(position, moved[:3, 3])
