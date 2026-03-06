/* Minimal os_support.h stub for standalone RNNoise build */
#ifndef OS_SUPPORT_H
#define OS_SUPPORT_H

#include <stdlib.h>
#include <string.h>

#ifndef OPUS_ALLOC
#define OPUS_ALLOC(size) malloc(size)
#endif

#ifndef OPUS_FREE
#define OPUS_FREE(ptr) free(ptr)
#endif

#ifndef OPUS_CLEAR
#define OPUS_CLEAR(dst, n) memset(dst, 0, (n) * sizeof(*(dst)))
#endif

#ifndef OPUS_COPY
#define OPUS_COPY(dst, src, n) memcpy(dst, src, (n) * sizeof(*(dst)))
#endif

#ifndef OPUS_MOVE
#define OPUS_MOVE(dst, src, n) memmove(dst, src, (n) * sizeof(*(dst)))
#endif

#endif /* OS_SUPPORT_H */
