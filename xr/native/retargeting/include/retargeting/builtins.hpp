// Explicit registration of the algorithms shipped with the toolkit.
//
// Self-registration via static initializers is unreliable when the algorithms
// live in a static library (the linker drops translation units nothing
// references). Calling this function guarantees the built-in algorithms ("gmr",
// and future ones) are present in the AlgorithmRegistry. It is idempotent, and
// the business-layer factories call it for you, so most callers never need to.
#pragma once

namespace retargeting {

void register_builtin_algorithms();

}  // namespace retargeting
