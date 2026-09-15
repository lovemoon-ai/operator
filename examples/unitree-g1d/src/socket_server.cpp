#include "operator_g1d/socket_server.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <cstring>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace operator_g1d {
namespace {

int make_socket(int family) {
  const int fd = ::socket(family, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    throw std::runtime_error(std::string("socket failed: ") + std::strerror(errno));
  }
  return fd;
}

void listen_or_throw(int fd) {
  if (::listen(fd, 1) != 0) {
    throw std::runtime_error(std::string("listen failed: ") + std::strerror(errno));
  }
}

}  // namespace

Listener::Listener(const std::string& endpoint) : endpoint_(endpoint) {
  if (endpoint.rfind("uds:", 0) == 0) {
    unix_path_ = endpoint.substr(4);
    if (unix_path_.empty() || unix_path_.size() >= sizeof(sockaddr_un::sun_path)) {
      throw std::runtime_error("invalid UDS endpoint path");
    }
    fd_ = make_socket(AF_UNIX);
    ::unlink(unix_path_.c_str());
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, unix_path_.c_str(), sizeof(address.sun_path) - 1);
    if (::bind(fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
      const std::string error = std::strerror(errno);
      ::close(fd_);
      fd_ = -1;
      throw std::runtime_error("bind " + endpoint + " failed: " + error);
    }
    listen_or_throw(fd_);
    return;
  }

  if (endpoint.rfind("tcp:", 0) == 0) {
    const std::string address_text = endpoint.substr(4);
    const auto separator = address_text.rfind(':');
    if (separator == std::string::npos) {
      throw std::runtime_error("TCP endpoint must be tcp:<IPv4>:<port>");
    }
    const std::string host = address_text.substr(0, separator);
    const int port = std::stoi(address_text.substr(separator + 1));
    if (port <= 0 || port > 65535) {
      throw std::runtime_error("TCP endpoint port is out of range");
    }

    fd_ = make_socket(AF_INET);
    int reuse = 1;
    ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<std::uint16_t>(port));
    if (::inet_pton(AF_INET, host.c_str(), &address.sin_addr) != 1) {
      ::close(fd_);
      fd_ = -1;
      throw std::runtime_error("TCP endpoint host must be an IPv4 address");
    }
    if (::bind(fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
      const std::string error = std::strerror(errno);
      ::close(fd_);
      fd_ = -1;
      throw std::runtime_error("bind " + endpoint + " failed: " + error);
    }
    listen_or_throw(fd_);
    return;
  }

  throw std::runtime_error("endpoint must start with uds: or tcp:");
}

Listener::~Listener() {
  if (fd_ >= 0) {
    ::close(fd_);
  }
  if (!unix_path_.empty()) {
    ::unlink(unix_path_.c_str());
  }
}

int Listener::accept_one(int timeout_ms) const {
  pollfd descriptor{fd_, POLLIN, 0};
  int result;
  do {
    result = ::poll(&descriptor, 1, timeout_ms);
  } while (result < 0 && errno == EINTR);
  if (result == 0) {
    return -1;
  }
  if (result < 0) {
    throw std::runtime_error(std::string("listener poll failed: ") + std::strerror(errno));
  }
  const int client = ::accept4(fd_, nullptr, nullptr, SOCK_CLOEXEC);
  if (client < 0) {
    if (errno == EINTR) {
      return -1;
    }
    throw std::runtime_error(std::string("accept failed: ") + std::strerror(errno));
  }
  return client;
}

const std::string& Listener::endpoint() const {
  return endpoint_;
}

}  // namespace operator_g1d
