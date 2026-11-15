#if defined(GHOSTTY_SIMD_INDEX_OF_H_) == defined(HWY_TARGET_TOGGLE)
#ifdef GHOSTTY_SIMD_INDEX_OF_H_
#undef GHOSTTY_SIMD_INDEX_OF_H_
#else
#define GHOSTTY_SIMD_INDEX_OF_H_
#endif

#include <hwy/highway.h>

#include <stddef.h>

HWY_BEFORE_NAMESPACE();
namespace ghostty {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

// Sentinel value returned by IndexOfChunk when no match is found.
static constexpr size_t kNotFound = static_cast<size_t>(-1);

// Return the index of the first occurrence of `needle` in `input`, where
// the input and needle are already loaded into vectors. Returns kNotFound
// if no match is found.
template <class D, typename T = hn::TFromD<D>>
size_t IndexOfChunk(D d,
                    hn::Vec<D> needle_vec,
                    hn::Vec<D> input_vec) {
  // Compare the input vector with the needle vector. This produces
  // a vector where each lane is 0xFF if the corresponding lane in
  // `input_vec` is equal to the corresponding lane in `needle_vec`.
  const hn::Mask<D> eq_mask = hn::Eq(needle_vec, input_vec);

  // Find the index within the vector where the first true value is.
  const intptr_t pos = hn::FindFirstTrue(d, eq_mask);

  // If we found a match, return the index into the input.
  if (pos >= 0) {
    return static_cast<size_t>(pos);
  } else {
    return kNotFound;
  }
}

}  // namespace HWY_NAMESPACE
}  // namespace ghostty
HWY_AFTER_NAMESPACE();

#endif  // GHOSTTY_SIMD_INDEX_OF_H_
