#ifndef RFB_RENDERING_C_H
#define RFB_RENDERING_C_H

#include <stddef.h>
#include <stdint.h>

/// Chroma planes contain only DC terms (coefficients[65..127] and [129..191] are zero).
#define RFB_DCT_FLAG_CHROMA_DC_ONLY 1u
/// Luma plane contains only its DC term (coefficients[1..63] are zero).
#define RFB_DCT_FLAG_LUMA_DC_ONLY   2u

/// Decode three 8x8 Apple DCT coefficient planes to 64 native BGRA pixels.
void rfb_apple_dct_tile_bgra(
    uint32_t output[64],
    const int16_t coefficients[192],
    const uint16_t luma_quantization[64],
    const uint16_t chroma_quantization[64]);

/// Decode three 8x8 Apple DCT coefficient planes directly into a BGRA
/// framebuffer region of size width x height (1..8 each) with row stride
/// `dst_stride` bytes. Pixel values are bit-identical to
/// `rfb_apple_dct_tile_bgra`.
void rfb_apple_dct_tile_bgra_stride(
    uint8_t *dst_row0,
    size_t dst_stride,
    int width,
    int height,
    const int16_t coefficients[192],
    const uint16_t luma_quantization[64],
    const uint16_t chroma_quantization[64],
    uint8_t flags);

/// Copy a rectangular 32-bit BGRX region into a BGRA surface while forcing the
/// alpha byte to 0xFF (NEON-vectorized on arm64).
void rfb_copy_bgrx_to_opaque_bgra(
    uint8_t *dst_row0,
    size_t dst_stride,
    const uint8_t *src_row0,
    size_t src_stride,
    int width,
    int height);

#endif
