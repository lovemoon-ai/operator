"""Product-property parsing only; no replacement for physical XR tests."""
from conftest import _device_kind, _product_identity


def test_pico_is_not_misidentified_by_android_vbmeta_properties():
    identity = _product_identity("""[ro.boot.vbmeta.device_state]: [locked]
[ro.product.manufacturer]: [Pico]
[ro.product.brand]: [Pico]
[ro.product.model]: [A9210]
[ro.product.device]: [sparrow]
""")
    assert _device_kind(identity) == "pico"


def test_quest_is_identified_by_product_properties():
    identity = _product_identity("""[ro.product.manufacturer]: [Oculus]
[ro.product.model]: [Quest 3]
[ro.product.device]: [eureka]
""")
    assert _device_kind(identity) == "quest"


def test_unrelated_android_metadata_cannot_make_a_phone_an_xr_device():
    identity = _product_identity("""[ro.boot.vbmeta.digest]: [meta]
[debug.application]: [pico quest]
[ro.product.manufacturer]: [Google]
[ro.product.model]: [Pixel 8]
""")
    assert _device_kind(identity) is None
