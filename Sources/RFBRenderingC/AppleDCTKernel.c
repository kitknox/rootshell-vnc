#include "RFBRenderingC.h"
#include <string.h>
// RFB_DCT_FORCE_SCALAR is used by the standalone portability checks.
#if defined(__aarch64__) && !defined(RFB_DCT_FORCE_SCALAR)
#define RFB_DCT_NEON 1
#include <arm_neon.h>
#else
#define RFB_DCT_NEON 0
#endif

// Integer DCT_ISLOW and YCbCr conversion derived from stb_image, which is
// public domain or MIT licensed. Keeping the integer biases and shifts is
// necessary for output identical to its ARM SIMD implementation.

// Unsigned intermediates make 32-bit wrapping explicit for extreme input.
// Cast back before arithmetic right shifts, matching the SIMD lane operations.
#define FSH(x) ((x) * 4096)
#define IDCT_1D(s0,s1,s2,s3,s4,s5,s6,s7) \
    uint32_t t0,t1,t2,t3,p1,p2,p3,p4,p5,x0,x1,x2,x3; \
    p2=(s2); p3=(s6); p1=(p2+p3)*2217; \
    t2=p1+p3*-7567; t3=p1+p2*3135; \
    p2=(s0); p3=(s4); t0=FSH(p2+p3); t1=FSH(p2-p3); \
    x0=t0+t3; x3=t0-t3; x1=t1+t2; x2=t1-t2; \
    t0=(s7); t1=(s5); t2=(s3); t3=(s1); \
    p3=t0+t2; p4=t1+t3; p1=t0+t3; p2=t1+t2; \
    p5=(p3+p4)*4816; t0*=1223; t1*=8410; t2*=12586; t3*=6149; \
    p1=p5+p1*-3685; p2=p5+p2*-10497; p3*=-8034; p4*=-1597; \
    t3+=p1+p4; t2+=p2+p3; t1+=p2+p4; t0+=p1+p3

static uint8_t clamp_u8(int value) {
    if ((unsigned)value > 255) return value < 0 ? 0 : 255;
    return (uint8_t)value;
}

static void idct_block(uint8_t output[64], const int16_t input[64]) {
    int values[64];
    int *v = values;
    const int16_t *d = input;
    for (int column = 0; column < 8; ++column, ++d, ++v) {
        if (d[8]==0 && d[16]==0 && d[24]==0 && d[32]==0 &&
            d[40]==0 && d[48]==0 && d[56]==0) {
            int dc = d[0] * 4;
            v[0]=v[8]=v[16]=v[24]=v[32]=v[40]=v[48]=v[56]=dc;
        } else {
            IDCT_1D(d[0],d[8],d[16],d[24],d[32],d[40],d[48],d[56]);
            x0+=512; x1+=512; x2+=512; x3+=512;
            v[0]=(int32_t)(x0+t3)>>10; v[56]=(int32_t)(x0-t3)>>10;
            v[8]=(int32_t)(x1+t2)>>10; v[48]=(int32_t)(x1-t2)>>10;
            v[16]=(int32_t)(x2+t1)>>10; v[40]=(int32_t)(x2-t1)>>10;
            v[24]=(int32_t)(x3+t0)>>10; v[32]=(int32_t)(x3-t0)>>10;
        }
    }
    v = values;
    for (int row = 0; row < 8; ++row, v += 8) {
        IDCT_1D(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7]);
        x0+=65536+(128<<17); x1+=65536+(128<<17);
        x2+=65536+(128<<17); x3+=65536+(128<<17);
        output[row*8+0]=clamp_u8((int32_t)(x0+t3)>>17);
        output[row*8+7]=clamp_u8((int32_t)(x0-t3)>>17);
        output[row*8+1]=clamp_u8((int32_t)(x1+t2)>>17);
        output[row*8+6]=clamp_u8((int32_t)(x1-t2)>>17);
        output[row*8+2]=clamp_u8((int32_t)(x2+t1)>>17);
        output[row*8+5]=clamp_u8((int32_t)(x2-t1)>>17);
        output[row*8+3]=clamp_u8((int32_t)(x3+t0)>>17);
        output[row*8+4]=clamp_u8((int32_t)(x3-t0)>>17);
    }
}

#if RFB_DCT_NEON
// stb_image's ARM integer IDCT. It matches scalar DCT_ISLOW while its 16-bit
// intermediates fit; larger inputs retain the original ARM narrowing behavior.
static void idct_block_neon(uint8_t *out, const int16_t data[64]) {
    int16x8_t row0,row1,row2,row3,row4,row5,row6,row7;
    int16x4_t rot0_0=vdup_n_s16(2217),rot0_1=vdup_n_s16(-7567),rot0_2=vdup_n_s16(3135);
    int16x4_t rot1_0=vdup_n_s16(4816),rot1_1=vdup_n_s16(-3685),rot1_2=vdup_n_s16(-10497);
    int16x4_t rot2_0=vdup_n_s16(-8034),rot2_1=vdup_n_s16(-1597);
    int16x4_t rot3_0=vdup_n_s16(1223),rot3_1=vdup_n_s16(8410);
    int16x4_t rot3_2=vdup_n_s16(12586),rot3_3=vdup_n_s16(6149);
#define LM(out,in,co) int32x4_t out##_l=vmull_s16(vget_low_s16(in),co); int32x4_t out##_h=vmull_s16(vget_high_s16(in),co)
#define LMA(out,ac,in,co) int32x4_t out##_l=vmlal_s16(ac##_l,vget_low_s16(in),co); int32x4_t out##_h=vmlal_s16(ac##_h,vget_high_s16(in),co)
#define WID(out,in) int32x4_t out##_l=vshll_n_s16(vget_low_s16(in),12); int32x4_t out##_h=vshll_n_s16(vget_high_s16(in),12)
#define WADD(out,a,b) int32x4_t out##_l=vaddq_s32(a##_l,b##_l); int32x4_t out##_h=vaddq_s32(a##_h,b##_h)
#define WSUB(out,a,b) int32x4_t out##_l=vsubq_s32(a##_l,b##_l); int32x4_t out##_h=vsubq_s32(a##_h,b##_h)
#define BFLY(out0,out1,a,b,shiftop,s) { WADD(sum,a,b); WSUB(dif,a,b); out0=vcombine_s16(shiftop(sum_l,s),shiftop(sum_h,s)); out1=vcombine_s16(shiftop(dif_l,s),shiftop(dif_h,s)); }
#define PASS(shiftop,shift) { \
    int16x8_t sum26=vaddq_s16(row2,row6); LM(p1e,sum26,rot0_0); LMA(t2e,p1e,row6,rot0_1); LMA(t3e,p1e,row2,rot0_2); \
    int16x8_t sum04=vaddq_s16(row0,row4),dif04=vsubq_s16(row0,row4); WID(t0e,sum04); WID(t1e,dif04); \
    WADD(x0,t0e,t3e); WSUB(x3,t0e,t3e); WADD(x1,t1e,t2e); WSUB(x2,t1e,t2e); \
    int16x8_t sum15=vaddq_s16(row1,row5),sum17=vaddq_s16(row1,row7),sum35=vaddq_s16(row3,row5),sum37=vaddq_s16(row3,row7); \
    int16x8_t sumodd=vaddq_s16(sum17,sum35); LM(p5o,sumodd,rot1_0); LMA(p1o,p5o,sum17,rot1_1); LMA(p2o,p5o,sum35,rot1_2); \
    LM(p3o,sum37,rot2_0); LM(p4o,sum15,rot2_1); WADD(sump13o,p1o,p3o); WADD(sump24o,p2o,p4o); WADD(sump23o,p2o,p3o); WADD(sump14o,p1o,p4o); \
    LMA(x4,sump13o,row7,rot3_0); LMA(x5,sump24o,row5,rot3_1); LMA(x6,sump23o,row3,rot3_2); LMA(x7,sump14o,row1,rot3_3); \
    BFLY(row0,row7,x0,x7,shiftop,shift); BFLY(row1,row6,x1,x6,shiftop,shift); BFLY(row2,row5,x2,x5,shiftop,shift); BFLY(row3,row4,x3,x4,shiftop,shift); }
    row0=vld1q_s16(data); row1=vld1q_s16(data+8); row2=vld1q_s16(data+16); row3=vld1q_s16(data+24);
    row4=vld1q_s16(data+32); row5=vld1q_s16(data+40); row6=vld1q_s16(data+48); row7=vld1q_s16(data+56);
    row0=vaddq_s16(row0,vsetq_lane_s16(1024,vdupq_n_s16(0),0));
    PASS(vrshrn_n_s32,10);
#define T16(x,y) {int16x8x2_t t=vtrnq_s16(x,y);x=t.val[0];y=t.val[1];}
#define T32(x,y) {int32x4x2_t t=vtrnq_s32(vreinterpretq_s32_s16(x),vreinterpretq_s32_s16(y));x=vreinterpretq_s16_s32(t.val[0]);y=vreinterpretq_s16_s32(t.val[1]);}
#define T64(x,y) {int16x8_t a=x,b=y;x=vcombine_s16(vget_low_s16(a),vget_low_s16(b));y=vcombine_s16(vget_high_s16(a),vget_high_s16(b));}
    T16(row0,row1);T16(row2,row3);T16(row4,row5);T16(row6,row7);
    T32(row0,row2);T32(row1,row3);T32(row4,row6);T32(row5,row7);
    T64(row0,row4);T64(row1,row5);T64(row2,row6);T64(row3,row7);
    PASS(vshrn_n_s32,16);
    uint8x8_t p0=vqrshrun_n_s16(row0,1),p1=vqrshrun_n_s16(row1,1),p2=vqrshrun_n_s16(row2,1),p3=vqrshrun_n_s16(row3,1);
    uint8x8_t p4=vqrshrun_n_s16(row4,1),p5=vqrshrun_n_s16(row5,1),p6=vqrshrun_n_s16(row6,1),p7=vqrshrun_n_s16(row7,1);
#define T8(x,y) {uint8x8x2_t t=vtrn_u8(x,y);x=t.val[0];y=t.val[1];}
#define T816(x,y) {uint16x4x2_t t=vtrn_u16(vreinterpret_u16_u8(x),vreinterpret_u16_u8(y));x=vreinterpret_u8_u16(t.val[0]);y=vreinterpret_u8_u16(t.val[1]);}
#define T832(x,y) {uint32x2x2_t t=vtrn_u32(vreinterpret_u32_u8(x),vreinterpret_u32_u8(y));x=vreinterpret_u8_u32(t.val[0]);y=vreinterpret_u8_u32(t.val[1]);}
    T8(p0,p1);T8(p2,p3);T8(p4,p5);T8(p6,p7);T816(p0,p2);T816(p1,p3);T816(p4,p6);T816(p5,p7);T832(p0,p4);T832(p1,p5);T832(p2,p6);T832(p3,p7);
    vst1_u8(out,p0);vst1_u8(out+8,p1);vst1_u8(out+16,p2);vst1_u8(out+24,p3);vst1_u8(out+32,p4);vst1_u8(out+40,p5);vst1_u8(out+48,p6);vst1_u8(out+56,p7);
#undef LM
#undef LMA
#undef WID
#undef WADD
#undef WSUB
#undef BFLY
#undef PASS
#undef T16
#undef T32
#undef T64
#undef T8
#undef T816
#undef T832
}
#endif

static uint32_t ycbcr_to_bgra(uint8_t y, uint8_t cb_byte, uint8_t cr_byte) {
    int y_fixed=((int)y<<20)+(1<<19);
    int cb=(int)cb_byte-128, cr=(int)cr_byte-128;
    int r=(y_fixed+cr*(5743<<8))>>20;
    int green_cb=(int32_t)((uint32_t)(cb*-(1410<<8))&0xffff0000u);
    int g=(y_fixed+cr*-(2925<<8)+green_cb)>>20;
    int b=(y_fixed+cb*(7258<<8))>>20;
    return 0xff000000u | ((uint32_t)clamp_u8(r)<<16) |
        ((uint32_t)clamp_u8(g)<<8) | clamp_u8(b);
}

// The DC shortcut must preserve the ARM kernel's 16-bit narrowing, including
// unusual quantization tables that wrap the dequantized coefficient.
static uint8_t idct_dc(int16_t dc) {
#if RFB_DCT_NEON
    int16_t intermediate = (int16_t)((int16_t)(dc + 1024) * 4);
    return clamp_u8(((int)intermediate + 16) >> 5);
#else
    return clamp_u8((((int)dc + 4) >> 3) + 128);
#endif
}

#if RFB_DCT_NEON
// Convert eight pixels together, retaining the scalar green-Cb mask before
// adding Cr and the rounding bias. Saturating narrows implement clamp_u8.
static void ycbcr_row_bgra(uint32_t *output, const uint8_t *y,
                           const uint8_t *cb, const uint8_t *cr) {
    int16x8_t yy = vreinterpretq_s16_u16(vmovl_u8(vld1_u8(y)));
    int16x8_t cc = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vld1_u8(cb))), vdupq_n_s16(128));
    int16x8_t rr = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vld1_u8(cr))), vdupq_n_s16(128));
    // Coefficients are multiples of 256. Work at 12 fractional bits and
    // retain the equivalent low-eight-bit mask on the green Cb term.
#define COLOR_HALF(suffix, half) \
    int32x4_t yf_##suffix = vaddq_s32(vshll_n_s16(half(yy), 12), vdupq_n_s32(2048)); \
    int32x4_t red_##suffix = vmlal_n_s16(yf_##suffix, half(rr), 5743); \
    int32x4_t cbg_##suffix = vmull_n_s16(half(cc), -1410); \
    cbg_##suffix = vandq_s32(cbg_##suffix, vdupq_n_s32(-256)); \
    int32x4_t green_##suffix = vaddq_s32(vmlal_n_s16(yf_##suffix, half(rr), -2925), cbg_##suffix); \
    int32x4_t blue_##suffix = vmlal_n_s16(yf_##suffix, half(cc), 7258)
    COLOR_HALF(lo, vget_low_s16);
    COLOR_HALF(hi, vget_high_s16);
#define CHANNEL(name) vqmovun_s16(vcombine_s16(vshrn_n_s32(name##_lo, 12), vshrn_n_s32(name##_hi, 12)))
    uint8x8x4_t bgra = {{CHANNEL(blue), CHANNEL(green), CHANNEL(red), vdup_n_u8(255)}};
    vst4_u8((uint8_t *)output, bgra);
#undef COLOR_HALF
#undef CHANNEL
}
#endif

static void fill_solid_tile_stride(
    uint8_t *dst_row0,
    size_t dst_stride,
    int width,
    int height,
    uint32_t color) {
#if RFB_DCT_NEON
    if (width == 8) {
        uint8x16_t fill = vreinterpretq_u8_u32(vdupq_n_u32(color));
        for (int row = 0; row < height; ++row) {
            uint8_t *dst = dst_row0 + (size_t)row * dst_stride;
            vst1q_u8(dst, fill);
            vst1q_u8(dst + 16, fill);
        }
        return;
    }
#endif
    uint32_t row_pixels[8];
    for (int col = 0; col < width; ++col) {
        row_pixels[col] = color;
    }
    size_t row_bytes = (size_t)width * 4;
    for (int row = 0; row < height; ++row) {
        memcpy(dst_row0 + (size_t)row * dst_stride, row_pixels, row_bytes);
    }
}

static void emit_constant_chroma_stride(
    uint8_t *dst_row0,
    size_t dst_stride,
    int width,
    int height,
    const uint8_t y_plane[64],
    uint8_t cb_byte,
    uint8_t cr_byte) {
    int cb = (int)cb_byte - 128;
    int cr = (int)cr_byte - 128;
    int r_off = (2048 + cr * 5743) >> 12;
    int g_off = (2048 - cr * 2925 + ((cb * -1410) & ~255)) >> 12;
    int b_off = (2048 + cb * 7258) >> 12;
#if RFB_DCT_NEON
    int16x8_t red = vdupq_n_s16((int16_t)r_off);
    int16x8_t green = vdupq_n_s16((int16_t)g_off);
    int16x8_t blue = vdupq_n_s16((int16_t)b_off);
    uint8x8_t alpha = vdup_n_u8(255);
    if (width == 8) {
        for (int row = 0; row < height; ++row) {
            int16x8_t yy = vreinterpretq_s16_u16(vmovl_u8(vld1_u8(y_plane + row * 8)));
            uint8x8x4_t bgra = {{vqmovun_s16(vaddq_s16(yy, blue)),
                                vqmovun_s16(vaddq_s16(yy, green)),
                                vqmovun_s16(vaddq_s16(yy, red)), alpha}};
            vst4_u8(dst_row0 + (size_t)row * dst_stride, bgra);
        }
        return;
    }
    uint32_t row_buf[8];
    size_t row_bytes = (size_t)width * 4;
    for (int row = 0; row < height; ++row) {
        int16x8_t yy = vreinterpretq_s16_u16(vmovl_u8(vld1_u8(y_plane + row * 8)));
        uint8x8x4_t bgra = {{vqmovun_s16(vaddq_s16(yy, blue)),
                            vqmovun_s16(vaddq_s16(yy, green)),
                            vqmovun_s16(vaddq_s16(yy, red)), alpha}};
        vst4_u8((uint8_t *)row_buf, bgra);
        memcpy(dst_row0 + (size_t)row * dst_stride, row_buf, row_bytes);
    }
#else
    uint32_t row_buf[8];
    size_t row_bytes = (size_t)width * 4;
    for (int row = 0; row < height; ++row) {
        const uint8_t *y_row = y_plane + row * 8;
        for (int col = 0; col < width; ++col) {
            int y = (int)y_row[col];
            row_buf[col] = 0xff000000u
                | ((uint32_t)clamp_u8(y + r_off) << 16)
                | ((uint32_t)clamp_u8(y + g_off) << 8)
                | (uint32_t)clamp_u8(y + b_off);
        }
        memcpy(dst_row0 + (size_t)row * dst_stride, row_buf, row_bytes);
    }
#endif
}

static int dequantize_plane(
    int16_t dequantized[64],
    const int16_t *source,
    const uint16_t *quant
#if RFB_DCT_NEON && !defined(__OPTIMIZE__)
    , unsigned *out_magnitude
#endif
) {
#if RFB_DCT_NEON
    int16x8_t values = vmulq_s16(vld1q_s16(source), vreinterpretq_s16_u16(vld1q_u16(quant)));
    vst1q_s16(dequantized, values);
    int16x8_t ac_values = vsetq_lane_s16(0, values, 0);
#if !defined(__OPTIMIZE__)
    unsigned magnitude = vaddlvq_u16(vreinterpretq_u16_s16(vabsq_s16(values)));
#endif
    for (int i = 8; i < 64; i += 8) {
        values = vmulq_s16(vld1q_s16(source + i), vreinterpretq_s16_u16(vld1q_u16(quant + i)));
        vst1q_s16(dequantized + i, values);
        ac_values = vorrq_s16(ac_values, values);
#if !defined(__OPTIMIZE__)
        magnitude += vaddlvq_u16(vreinterpretq_u16_s16(vabsq_s16(values)));
#endif
    }
#if !defined(__OPTIMIZE__)
    *out_magnitude = magnitude;
#endif
    return (int)vmaxvq_u16(vreinterpretq_u16_s16(ac_values));
#else
    int ac = 0;
    for (int i = 0; i < 64; ++i) {
        int16_t value = (int16_t)((uint32_t)(uint16_t)source[i] * (uint32_t)quant[i]);
        dequantized[i] = value;
        if (i != 0) ac |= (uint16_t)value;
    }
    return ac;
#endif
}

static void run_idct(
    uint8_t output[64],
    const int16_t dequantized[64]
#if RFB_DCT_NEON && !defined(__OPTIMIZE__)
    , unsigned magnitude
#endif
) {
#if RFB_DCT_NEON
#if !defined(__OPTIMIZE__)
    // At -O0 NEON intrinsics spill many intermediates. The scalar routine
    // is faster there for small blocks. This conservative L1 bound keeps
    // every 16-bit sum/narrow in the ARM transform in range (including its
    // DC bias), so scalar and ARM rounding are identical. Larger blocks
    // must retain the ARM wrapping behavior.
    if (magnitude <= 2048) idct_block(output, dequantized);
    else idct_block_neon(output, dequantized);
#else
    idct_block_neon(output, dequantized);
#endif
#else
    idct_block(output, dequantized);
#endif
}

void rfb_apple_dct_tile_bgra_stride(
    uint8_t *dst_row0,
    size_t dst_stride,
    int width,
    int height,
    const int16_t coefficients[192],
    const uint16_t luma_quantization[64],
    const uint16_t chroma_quantization[64],
    uint8_t flags) {
    if (width <= 0 || height <= 0) return;
    if (width > 8) width = 8;
    if (height > 8) height = 8;

    int16_t dequantized[64];
    uint8_t planes[192];
    uint8_t constant_value[3] = {0, 0, 0};
    int constant_planes = 0;

    if ((flags & (RFB_DCT_FLAG_CHROMA_DC_ONLY | RFB_DCT_FLAG_LUMA_DC_ONLY))
        == (RFB_DCT_FLAG_CHROMA_DC_ONLY | RFB_DCT_FLAG_LUMA_DC_ONLY)) {
        uint8_t y_dc = idct_dc((int16_t)((uint32_t)(uint16_t)coefficients[0] * (uint32_t)luma_quantization[0]));
        uint8_t cb_dc = idct_dc((int16_t)((uint32_t)(uint16_t)coefficients[64] * (uint32_t)chroma_quantization[0]));
        uint8_t cr_dc = idct_dc((int16_t)((uint32_t)(uint16_t)coefficients[128] * (uint32_t)chroma_quantization[0]));
        fill_solid_tile_stride(dst_row0, dst_stride, width, height, ycbcr_to_bgra(y_dc, cb_dc, cr_dc));
        return;
    }

    if (flags & RFB_DCT_FLAG_CHROMA_DC_ONLY) {
        uint8_t cb_dc = idct_dc((int16_t)((uint32_t)(uint16_t)coefficients[64] * (uint32_t)chroma_quantization[0]));
        uint8_t cr_dc = idct_dc((int16_t)((uint32_t)(uint16_t)coefficients[128] * (uint32_t)chroma_quantization[0]));
#if RFB_DCT_NEON && !defined(__OPTIMIZE__)
        unsigned magnitude = 0;
        int ac = dequantize_plane(dequantized, coefficients, luma_quantization, &magnitude);
#else
        int ac = dequantize_plane(dequantized, coefficients, luma_quantization);
#endif
        if (ac == 0) {
            uint8_t y_dc = idct_dc(dequantized[0]);
            fill_solid_tile_stride(dst_row0, dst_stride, width, height, ycbcr_to_bgra(y_dc, cb_dc, cr_dc));
            return;
        }
#if RFB_DCT_NEON && !defined(__OPTIMIZE__)
        run_idct(planes, dequantized, magnitude);
#else
        run_idct(planes, dequantized);
#endif
        emit_constant_chroma_stride(dst_row0, dst_stride, width, height, planes, cb_dc, cr_dc);
        return;
    }

    for (int plane = 0; plane < 3; ++plane) {
        const uint16_t *quant = plane == 0 ? luma_quantization : chroma_quantization;
        const int16_t *source = coefficients + plane * 64;
        if (plane == 0 && (flags & RFB_DCT_FLAG_LUMA_DC_ONLY)) {
            constant_value[0] = idct_dc((int16_t)((uint32_t)(uint16_t)source[0] * (uint32_t)quant[0]));
            constant_planes |= 1;
            continue;
        }
#if RFB_DCT_NEON && !defined(__OPTIMIZE__)
        unsigned magnitude = 0;
        int ac = dequantize_plane(dequantized, source, quant, &magnitude);
#else
        int ac = dequantize_plane(dequantized, source, quant);
#endif
        if (ac == 0) {
            constant_value[plane] = idct_dc(dequantized[0]);
            constant_planes |= 1 << plane;
            continue;
        }
#if RFB_DCT_NEON && !defined(__OPTIMIZE__)
        run_idct(planes + plane * 64, dequantized, magnitude);
#else
        run_idct(planes + plane * 64, dequantized);
#endif
    }

    if (constant_planes == 7) {
        uint32_t color = ycbcr_to_bgra(constant_value[0], constant_value[1], constant_value[2]);
        fill_solid_tile_stride(dst_row0, dst_stride, width, height, color);
        return;
    }

    if ((constant_planes & 6) == 6) {
        emit_constant_chroma_stride(
            dst_row0, dst_stride, width, height, planes, constant_value[1], constant_value[2]);
        return;
    }

    // Materialize any remaining constant plane(s) before full YCbCr conversion.
    for (int plane = 0; plane < 3; ++plane) {
        if (constant_planes & (1 << plane)) {
            memset(planes + plane * 64, constant_value[plane], 64);
        }
    }

#if RFB_DCT_NEON && defined(__OPTIMIZE__)
    if (width == 8) {
        for (int row = 0; row < height; ++row) {
            int offset = row * 8;
            ycbcr_row_bgra(
                (uint32_t *)(dst_row0 + (size_t)row * dst_stride),
                planes + offset, planes + 64 + offset, planes + 128 + offset);
        }
    } else {
        uint32_t row_buf[8];
        size_t row_bytes = (size_t)width * 4;
        for (int row = 0; row < height; ++row) {
            int offset = row * 8;
            ycbcr_row_bgra(row_buf, planes + offset, planes + 64 + offset, planes + 128 + offset);
            memcpy(dst_row0 + (size_t)row * dst_stride, row_buf, row_bytes);
        }
    }
#else
    uint32_t row_buf[8];
    size_t row_bytes = (size_t)width * 4;
    for (int row = 0; row < height; ++row) {
        int offset = row * 8;
        for (int col = 0; col < width; ++col) {
            row_buf[col] = ycbcr_to_bgra(
                planes[offset + col], planes[64 + offset + col], planes[128 + offset + col]);
        }
        memcpy(dst_row0 + (size_t)row * dst_stride, row_buf, row_bytes);
    }
#endif
}

void rfb_apple_dct_tile_bgra(
    uint32_t output[64], const int16_t coefficients[192],
    const uint16_t luma_quantization[64],
    const uint16_t chroma_quantization[64]) {
    rfb_apple_dct_tile_bgra_stride(
        (uint8_t *)output, 8 * sizeof(uint32_t), 8, 8,
        coefficients, luma_quantization, chroma_quantization, 0);
}

void rfb_copy_bgrx_to_opaque_bgra(
    uint8_t *dst_row0,
    size_t dst_stride,
    const uint8_t *src_row0,
    size_t src_stride,
    int width,
    int height) {
    if (width <= 0 || height <= 0) return;
#if RFB_DCT_NEON
    uint8x16_t alpha_mask = vreinterpretq_u8_u32(vdupq_n_u32(0xff000000u));
#endif
    for (int row = 0; row < height; ++row) {
        uint8_t *dst = dst_row0 + (size_t)row * dst_stride;
        const uint8_t *src = src_row0 + (size_t)row * src_stride;
        int x = 0;
#if RFB_DCT_NEON
        for (; x + 16 <= width; x += 16) {
            size_t off = (size_t)x * 4;
            uint8x16_t v0 = vorrq_u8(vld1q_u8(src + off), alpha_mask);
            uint8x16_t v1 = vorrq_u8(vld1q_u8(src + off + 16), alpha_mask);
            uint8x16_t v2 = vorrq_u8(vld1q_u8(src + off + 32), alpha_mask);
            uint8x16_t v3 = vorrq_u8(vld1q_u8(src + off + 48), alpha_mask);
            vst1q_u8(dst + off, v0);
            vst1q_u8(dst + off + 16, v1);
            vst1q_u8(dst + off + 32, v2);
            vst1q_u8(dst + off + 48, v3);
        }
        for (; x + 4 <= width; x += 4) {
            size_t off = (size_t)x * 4;
            vst1q_u8(dst + off, vorrq_u8(vld1q_u8(src + off), alpha_mask));
        }
#endif
        for (; x < width; ++x) {
            size_t off = (size_t)x * 4;
            uint32_t pixel;
            memcpy(&pixel, src + off, 4);
            pixel |= 0xff000000u;
            memcpy(dst + off, &pixel, 4);
        }
    }
}
