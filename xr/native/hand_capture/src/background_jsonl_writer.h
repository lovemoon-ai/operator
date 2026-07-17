// background_jsonl_writer.h — shared background-thread JSONL file writer.
//
// Lines are serialized on the caller's thread (cheap snprintf/append work)
// and flushed to disk on a dedicated writer thread so file I/O never blocks
// the render loop. One instance per file. Bounded queue: when the writer
// thread stalls, lines are dropped and counted instead of growing without
// bound (~16 MB worst case at ~4 KB/line).

#ifndef HAND_CAPTURE_BACKGROUND_JSONL_WRITER_H
#define HAND_CAPTURE_BACKGROUND_JSONL_WRITER_H

#include <godot_cpp/variant/string.hpp>

#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace godot {

class BackgroundJsonlWriter {
public:
    BackgroundJsonlWriter() = default;
    ~BackgroundJsonlWriter();
    BackgroundJsonlWriter(const BackgroundJsonlWriter &) = delete;
    BackgroundJsonlWriter &operator=(const BackgroundJsonlWriter &) = delete;

    // Main-thread API.
    bool begin(const String &p_absolute_path);
    void end();
    bool active() const { return running_; }
    void enqueue(std::string &&p_line);

    // Metrics (main thread only — enqueue/pop happen on the same thread).
    uint64_t pop_lines() {
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t v = lines_;
        lines_ = 0;
        return v;
    }
    uint64_t pop_dropped() {
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t v = dropped_;
        dropped_ = 0;
        return v;
    }

private:
    void thread_main();

    static constexpr size_t kMaxQueuedLines = 4096;

    std::thread thread_;
    std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<std::string> queue_;
    bool running_ = false;
    FILE *file_ = nullptr;
    uint64_t lines_ = 0;
    uint64_t dropped_ = 0;
};

} // namespace godot

#endif // HAND_CAPTURE_BACKGROUND_JSONL_WRITER_H
