package com.cloudwebrtc.webrtc.audio;

import android.util.Log;
import java.nio.ByteBuffer;

/**
 * RNNoise-based noise/residual-echo suppressor.
 * Runs as a capturePostProcessing stage after WebRTC's built-in AEC3.
 *
 * RNNoise operates at 48kHz with 480-sample frames (10ms).
 * For other sample rates, processing is skipped.
 */
public class RNNoiseProcessor implements AudioProcessingAdapter.ExternalAudioFrameProcessing {
    private static final String TAG = "RNNoiseProcessor";

    private long nativeState = 0;
    private int sampleRate = 0;
    private int numChannels = 1;
    private boolean active = false;
    private int processCount = 0;

    static {
        try {
            System.loadLibrary("rnnoise_jni");
            Log.i(TAG, "rnnoise_jni library loaded");
        } catch (UnsatisfiedLinkError e) {
            Log.e(TAG, "Failed to load rnnoise_jni: " + e.getMessage());
        }
    }

    @Override
    public void initialize(int sampleRateHz, int numChannels) {
        this.sampleRate = sampleRateHz;
        this.numChannels = numChannels;

        if (nativeState != 0) {
            nativeDestroy(nativeState);
            nativeState = 0;
        }

        // RNNoise only supports 48kHz
        if (sampleRateHz == 48000) {
            nativeState = nativeCreate();
            active = true;
            Log.i(TAG, "Initialized: rate=" + sampleRateHz + " ch=" + numChannels
                    + " frameSize=" + nativeGetFrameSize());
        } else {
            active = false;
            Log.w(TAG, "Unsupported sample rate " + sampleRateHz + "Hz, RNNoise disabled (48kHz only)");
        }
    }

    @Override
    public void reset(int newRate) {
        Log.i(TAG, "Reset: newRate=" + newRate);
        initialize(newRate, numChannels);
    }

    @Override
    public void process(int numBands, int numFrames, ByteBuffer buffer) {
        if (!active || nativeState == 0) return;

        processCount++;
        if (processCount <= 5 || processCount % 500 == 0) {
            Log.i(TAG, "process: bands=" + numBands + " frames=" + numFrames
                    + " bufCap=" + buffer.capacity() + " count=" + processCount);
        }

        // Buffer is float data from WebRTC (not int16!)
        // numFrames = total float values in buffer
        if (numFrames != 480) return;

        float vad = nativeProcessFloat(nativeState, buffer, numFrames, numBands);
        if (processCount <= 5) {
            Log.i(TAG, "RNNoise processed (float): vad=" + vad);
        }
    }

    public void release() {
        if (nativeState != 0) {
            nativeDestroy(nativeState);
            nativeState = 0;
            active = false;
            Log.i(TAG, "Released");
        }
    }

    // Native methods
    private native long nativeCreate();
    private native void nativeDestroy(long state);
    private native int nativeGetFrameSize();
    private native float nativeProcessFloat(long state, ByteBuffer buffer, int totalFloats, int numBands);
}
