// background_jsonl_writer.cpp — see header.

#include "background_jsonl_writer.h"

#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

BackgroundJsonlWriter::~BackgroundJsonlWriter() {
    end();
}

bool BackgroundJsonlWriter::begin(const String &p_absolute_path) {
    end();
    if (p_absolute_path.is_empty()) {
        return false;
    }
    CharString path_utf8 = p_absolute_path.utf8();
    FILE *file = std::fopen(path_utf8.get_data(), "wb");
    if (file == nullptr) {
        UtilityFunctions::push_warning(
                "BackgroundJsonlWriter: cannot open ", p_absolute_path);
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        file_ = file;
        running_ = true;
        queue_.clear();
    }
    thread_ = std::thread(&BackgroundJsonlWriter::thread_main, this);
    return true;
}

void BackgroundJsonlWriter::end() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ && file_ == nullptr) {
            return;
        }
        running_ = false;
    }
    cv_.notify_all();
    if (thread_.joinable()) {
        thread_.join();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (file_ != nullptr) {
        std::fclose(file_);
        file_ = nullptr;
    }
    queue_.clear();
}

void BackgroundJsonlWriter::enqueue(std::string &&p_line) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_) {
            return;
        }
        if (queue_.size() >= kMaxQueuedLines) {
            dropped_ += 1;
            return;
        }
        queue_.push_back(std::move(p_line));
        lines_ += 1;
    }
    cv_.notify_one();
}

void BackgroundJsonlWriter::thread_main() {
    std::vector<std::string> batch;
    while (true) {
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this] { return !queue_.empty() || !running_; });
            batch.swap(queue_);
            if (batch.empty() && !running_) {
                return;
            }
        }
        FILE *file = file_; // Owned by this thread between begin/end.
        if (file != nullptr) {
            for (const std::string &record : batch) {
                std::fwrite(record.data(), 1, record.size(), file);
                std::fputc('\n', file);
            }
            std::fflush(file);
        }
        batch.clear();
    }
}

} // namespace godot
