#ifndef KRAKEN_JPEG_H
#define KRAKEN_JPEG_H

#include <stddef.h>

unsigned char *kraken_jpeg_encode(const unsigned char *rgba, int width, int height,
                                  int quality, size_t *out_size);
void kraken_jpeg_free(unsigned char *buffer);

#endif
