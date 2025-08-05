// g711.h
#ifndef G711_H
#define G711_H

#ifdef __cplusplus
extern "C" {
#endif

// Definições para u-law e A-law
#define G711_ULAW 0
#define G711_ALAW 1

// Converte PCM de 16-bit para G.711
unsigned char linear_to_g711(short pcm_val, int format);

// Converte G.711 para PCM de 16-bit
short g711_to_linear(unsigned char g711_val, int format);

// Funções de conveniência para buffers
void g711_encode(short* pcm_in, unsigned char* g711_out, int count, int format);
void g711_decode(unsigned char* g711_in, short* pcm_out, int count, int format);

#ifdef __cplusplus
}
#endif

#endif //G711_H