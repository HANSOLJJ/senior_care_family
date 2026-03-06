#include <jni.h>
#include <string.h>
#include <android/log.h>
#include "rnnoise/rnnoise.h"

#define TAG "RNNoise"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

/* RNNoise frame size: 480 samples at 48kHz = 10ms */
#define RNNOISE_FRAME_SIZE 480

JNIEXPORT jlong JNICALL
Java_com_cloudwebrtc_webrtc_audio_RNNoiseProcessor_nativeCreate(
    JNIEnv *env, jobject thiz) {
    DenoiseState *st = rnnoise_create(NULL);
    LOGI("RNNoise created: %p, frame_size=%d", st, RNNOISE_FRAME_SIZE);
    return (jlong)(intptr_t)st;
}

JNIEXPORT void JNICALL
Java_com_cloudwebrtc_webrtc_audio_RNNoiseProcessor_nativeDestroy(
    JNIEnv *env, jobject thiz, jlong state) {
    DenoiseState *st = (DenoiseState *)(intptr_t)state;
    if (st) {
        rnnoise_destroy(st);
        LOGI("RNNoise destroyed");
    }
}

JNIEXPORT jint JNICALL
Java_com_cloudwebrtc_webrtc_audio_RNNoiseProcessor_nativeGetFrameSize(
    JNIEnv *env, jobject thiz) {
    return RNNOISE_FRAME_SIZE;
}

JNIEXPORT jfloat JNICALL
Java_com_cloudwebrtc_webrtc_audio_RNNoiseProcessor_nativeProcessFloat(
    JNIEnv *env, jobject thiz, jlong state, jobject byteBuffer,
    jint totalFloats, jint numBands) {

    DenoiseState *st = (DenoiseState *)(intptr_t)state;
    if (!st || !byteBuffer) return 0.0f;

    float *data = (float *)(*env)->GetDirectBufferAddress(env, byteBuffer);
    if (!data) return 0.0f;

    /*
     * WebRTC ExternalAudioProcessingFactory buffer format:
     *   - Data is float (not int16)
     *   - At 48kHz with 3 bands: buffer has 480 floats total
     *     layout: [band0: 160 floats][band1: 160][band2: 160]
     *   - RNNoise needs 480 contiguous samples of full-band signal
     *
     * Strategy: process all 480 floats as one block.
     * If it's truly band-split, band0 has most speech/echo energy,
     * and bands 1-2 get mild noise reduction as a bonus.
     * If it's actually full-band, this works perfectly.
     */
    if (totalFloats != RNNOISE_FRAME_SIZE) {
        return 0.0f;
    }

    float out_float[RNNOISE_FRAME_SIZE];
    float vad = rnnoise_process_frame(st, out_float, data);

    /* Write processed output back to the buffer */
    memcpy(data, out_float, RNNOISE_FRAME_SIZE * sizeof(float));

    return vad;
}
