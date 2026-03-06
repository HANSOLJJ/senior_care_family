cmake_minimum_required(VERSION 3.18.1)
project(rnnoise_jni C)

# RNNoise v0.2 source files (with pre-generated model data)
set(RNNOISE_SOURCES
    rnnoise/denoise.c
    rnnoise/kiss_fft.c
    rnnoise/pitch.c
    rnnoise/celt_lpc.c
    rnnoise/rnn.c
    rnnoise/nnet.c
    rnnoise/nnet_default.c
    rnnoise/rnnoise_data.c
    rnnoise/rnnoise_tables.c
    rnnoise/parse_lpcnet_weights.c
    rnnoise_jni.c
)

add_library(rnnoise_jni SHARED ${RNNOISE_SOURCES})

target_include_directories(rnnoise_jni PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/rnnoise
)

target_compile_definitions(rnnoise_jni PRIVATE
    RNNOISE_BUILD
    FLOAT_APPROX
)

target_compile_options(rnnoise_jni PRIVATE -O3)

find_library(log-lib log)
target_link_libraries(rnnoise_jni ${log-lib})
