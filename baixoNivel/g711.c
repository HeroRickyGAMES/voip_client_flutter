// g711.c
#include "g711.h"

static short seg_end[8] = {0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF, 0x3FFF, 0x7FFF};

static short search(short val, short* table, short size) {
    for (short i = 0; i < size; i++) {
        if (val <= table[i]) return i;
    }
    return size;
}

unsigned char linear_to_ulaw(short pcm_val) {
    short mask, seg;
    unsigned char uval;
    pcm_val = (pcm_val >> 2);
    if (pcm_val < 0) {
        pcm_val = -pcm_val;
        mask = 0x7F;
    } else {
        mask = 0xFF;
    }
    if (pcm_val > 8158) pcm_val = 8158;
    pcm_val += 33;
    seg = search(pcm_val, seg_end, 8);
    if (seg >= 8) return (0x7F ^ mask);
    uval = (seg << 4) | ((pcm_val >> (seg + 3)) & 0x0F);
    return (uval ^ mask);
}

short ulaw_to_linear(unsigned char u_val) {
    short t;
    u_val = ~u_val;
    t = ((u_val & 0x0F) << 3) + 33;
    t <<= ((u_val & 0x70) >> 4);
    return ((u_val & 0x80) ? (33 - t) : (t - 33));
}

unsigned char linear_to_g711(short pcm_val, int format) {
    if (format == G711_ULAW) return linear_to_ulaw(pcm_val);
    // A-law not implemented for simplicity
    return 0;
}

short g711_to_linear(unsigned char g711_val, int format) {
    if (format == G711_ULAW) return ulaw_to_linear(g711_val);
    // A-law not implemented for simplicity
    return 0;
}

// --- Nossas funções "exportadas" para a DLL ---
__declspec(dllexport) void encode_ulaw(unsigned char* pcm_in, int pcm_len, unsigned char* ulaw_out) {
    short* pcm = (short*)pcm_in;
    int num_samples = pcm_len / 2;
    for (int i = 0; i < num_samples; i++) {
        ulaw_out[i] = linear_to_ulaw(pcm[i]);
    }
}

__declspec(dllexport) void decode_ulaw(unsigned char* ulaw_in, int ulaw_len, unsigned char* pcm_out) {
    short* pcm = (short*)pcm_out;
    for (int i = 0; i < ulaw_len; i++) {
        pcm[i] = ulaw_to_linear(ulaw_in[i]);
    }
}