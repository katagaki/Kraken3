#include "kraken_jpeg.h"

/* jpeglib.h references FILE without pulling in stdio.h itself. */
#include <stdio.h>
#include <jpeglib.h>
#include <setjmp.h>
#include <stdlib.h>

/* libjpeg's default error handler exit()s the process, so route errors
   through longjmp back into the encode call instead. */
struct kraken_jpeg_error {
    struct jpeg_error_mgr mgr;
    jmp_buf jump;
};

static void kraken_jpeg_error_exit(j_common_ptr cinfo) {
    struct kraken_jpeg_error *err = (struct kraken_jpeg_error *)cinfo->err;
    longjmp(err->jump, 1);
}

unsigned char *kraken_jpeg_encode(const unsigned char *rgba, int width, int height,
                                  int quality, size_t *out_size) {
    struct jpeg_compress_struct cinfo;
    struct kraken_jpeg_error jerr;
    unsigned char *out = NULL;
    unsigned long out_len = 0;

    if (width <= 0 || height <= 0) return NULL;
    unsigned char *row = malloc((size_t)width * 3);
    if (!row) return NULL;

    cinfo.err = jpeg_std_error(&jerr.mgr);
    jerr.mgr.error_exit = kraken_jpeg_error_exit;
    if (setjmp(jerr.jump)) {
        jpeg_destroy_compress(&cinfo);
        free(row);
        free(out);
        return NULL;
    }

    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, &out, &out_len);
    cinfo.image_width = (JDIMENSION)width;
    cinfo.image_height = (JDIMENSION)height;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);
    jpeg_start_compress(&cinfo, TRUE);

    while (cinfo.next_scanline < cinfo.image_height) {
        const unsigned char *src = rgba + (size_t)cinfo.next_scanline * (size_t)width * 4;
        for (int x = 0; x < width; x++) {
            row[x * 3] = src[x * 4];
            row[x * 3 + 1] = src[x * 4 + 1];
            row[x * 3 + 2] = src[x * 4 + 2];
        }
        JSAMPROW rows[1] = { row };
        jpeg_write_scanlines(&cinfo, rows, 1);
    }

    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    free(row);
    *out_size = (size_t)out_len;
    return out;
}

void kraken_jpeg_free(unsigned char *buffer) {
    free(buffer);
}
