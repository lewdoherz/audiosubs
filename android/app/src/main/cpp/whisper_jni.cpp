#include <jni.h>
#include <whisper.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <cerrno>
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace {
struct Engine {
    whisper_context *context = nullptr;
    std::atomic<bool> cancelled{false};
    ~Engine() { if (context) whisper_free(context); }
};
void fail(JNIEnv *env, const char *message) {
    jclass type = env->FindClass("java/lang/IllegalStateException");
    if (type) { env->ThrowNew(type, message); env->DeleteLocalRef(type); }
}
bool abort_inference(void *data) {
    return static_cast<Engine *>(data)->cancelled.load(std::memory_order_relaxed);
}
bool begin_encoder(whisper_context *, whisper_state *, void *data) {
    return !abort_inference(data);
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_audiobook_1player_WhisperNative_open(JNIEnv *env, jobject, jstring path) {
    const char *value = env->GetStringUTFChars(path, nullptr);
    if (!value) return 0;
    std::unique_ptr<Engine> engine(new Engine());
    auto params = whisper_context_default_params();
    params.use_gpu = false;
    engine->context = whisper_init_from_file_with_params(value, params);
    env->ReleaseStringUTFChars(path, value);
    if (!engine->context) { fail(env, "Unable to load Whisper model (invalid file or insufficient memory)."); return 0; }
    return reinterpret_cast<jlong>(engine.release());
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_audiobook_1player_WhisperNative_abort(JNIEnv *, jobject, jlong handle) {
    reinterpret_cast<Engine *>(handle)->cancelled.store(true, std::memory_order_relaxed);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_audiobook_1player_WhisperNative_close(JNIEnv *, jobject, jlong handle) {
    delete reinterpret_cast<Engine *>(handle);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_audiobook_1player_WhisperNative_infer(
    JNIEnv *env, jobject, jlong handle, jobject buffer, jint samples,
    jstring language, jboolean translate, jobject sink) {
    auto *engine = reinterpret_cast<Engine *>(handle);
    auto *pcm = static_cast<float *>(env->GetDirectBufferAddress(buffer));
    if (!pcm || samples <= 0 || samples > 30 * WHISPER_SAMPLE_RATE ||
        env->GetDirectBufferCapacity(buffer) < static_cast<jlong>(samples) * sizeof(float)) {
        fail(env, "Invalid bounded PCM buffer."); return nullptr;
    }
    const char *lang = env->GetStringUTFChars(language, nullptr);
    if (!lang) return nullptr;
    std::string source(lang);
    env->ReleaseStringUTFChars(language, lang);
    if (source != "auto" && whisper_lang_id(source.c_str()) < 0) {
        fail(env, "Unsupported source language."); return nullptr;
    }
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = std::max(1u, std::min(4u, std::thread::hardware_concurrency()));
    params.translate = translate;
    params.language = source == "auto" ? nullptr : source.c_str();
    params.no_context = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.abort_callback = abort_inference;
    params.abort_callback_user_data = engine;
    params.encoder_begin_callback = begin_encoder;
    params.encoder_begin_callback_user_data = engine;
    const int result = whisper_full(engine->context, params, pcm, samples);
    if (abort_inference(engine)) { fail(env, "Transcription cancelled."); return nullptr; }
    if (result != 0) { fail(env, "Whisper inference failed."); return nullptr; }
    jclass type = env->GetObjectClass(sink);
    jmethodID callback = env->GetMethodID(type, "onSegment", "(JJ[B)V");
    env->DeleteLocalRef(type);
    if (!callback) return nullptr;
    const int64_t duration = static_cast<int64_t>(samples) * 1000 / WHISPER_SAMPLE_RATE;
    for (int i = 0; i < whisper_full_n_segments(engine->context); ++i) {
        if (abort_inference(engine)) { fail(env, "Transcription cancelled."); return nullptr; }
        const char *text = whisper_full_get_segment_text(engine->context, i);
        const auto start = std::clamp<int64_t>(whisper_full_get_segment_t0(engine->context, i) * 10, 0, duration);
        const auto end = std::clamp<int64_t>(whisper_full_get_segment_t1(engine->context, i) * 10, start, duration);
        const size_t length = std::strlen(text);
        jbyteArray bytes = env->NewByteArray(static_cast<jsize>(length));
        if (!bytes) return nullptr;
        env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(length), reinterpret_cast<const jbyte *>(text));
        env->CallVoidMethod(sink, callback, static_cast<jlong>(start), static_cast<jlong>(end), bytes);
        env->DeleteLocalRef(bytes);
        if (env->ExceptionCheck()) return nullptr;
    }
    const char *detected = whisper_lang_str(whisper_full_lang_id(engine->context));
    return env->NewStringUTF(detected ? detected : "auto");
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_audiobook_1player_WhisperNative_publish(
    JNIEnv *env, jobject, jbyteArray source, jbyteArray target) {
    const jsize source_len = env->GetArrayLength(source);
    const jsize target_len = env->GetArrayLength(target);
    std::string from(source_len, '\0'), to(target_len, '\0');
    env->GetByteArrayRegion(source, 0, source_len, reinterpret_cast<jbyte *>(from.data()));
    env->GetByteArrayRegion(target, 0, target_len, reinterpret_cast<jbyte *>(to.data()));
    if (env->ExceptionCheck()) return false;
    // RENAME_NOREPLACE publishes the complete inode atomically without clobbering
    // an output another job/user completed in the meantime. Never fall back to
    // an overwriting rename or a partially visible copy on unsupported volumes.
    if (syscall(SYS_renameat2, AT_FDCWD, from.c_str(), AT_FDCWD, to.c_str(), 1) == 0) return true;
    if (errno == EEXIST) return false;
    const std::string message = std::string("Atomic no-replace publication failed: ") + std::strerror(errno);
    fail(env, message.c_str());
    return false;
}
