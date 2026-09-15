#pragma once

#include <string>

namespace operator_g1d {

class Listener {
 public:
  explicit Listener(const std::string& endpoint);
  ~Listener();

  Listener(const Listener&) = delete;
  Listener& operator=(const Listener&) = delete;

  int accept_one(int timeout_ms) const;
  const std::string& endpoint() const;

 private:
  int fd_ = -1;
  std::string endpoint_;
  std::string unix_path_;
};

}  // namespace operator_g1d
