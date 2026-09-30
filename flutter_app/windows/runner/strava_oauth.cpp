// System-browser OAuth with a short-lived exclusive IPv4 loopback listener.
// No protocol registration, token exchange, cookie access, or persistent grant is
// performed here. Only the validated one-time code returns to Dart/Rust.
// Strava documents localhost/127.0.0.1 as allow-listed redirects:
// https://developers.strava.com/docs/authentication/
// Windows socket isolation: https://www.rfc-editor.org/rfc/rfc8252#appendix-B.3
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <shellapi.h>

#include "strava_oauth.h"
#include "oauth_validation.h"

#include <array>
#include <atomic>
#include <chrono>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
using Clock = std::chrono::steady_clock;
constexpr UINT kCompleteMessage = WM_APP + 0x583;
constexpr UINT_PTR kDeadlineTimer = 1;
constexpr wchar_t kWindowClass[] = L"HealthWorkoutExport.StravaOAuth.Dispatch.v1";

struct Outcome {
  std::string error;
  std::string message;
  std::string authorization_code;
};
class Socket {
 public:
  explicit Socket(SOCKET value = INVALID_SOCKET) : value_(value) {}
  ~Socket() { if (value_ != INVALID_SOCKET) closesocket(value_); }
  Socket(const Socket&) = delete;
  Socket& operator=(const Socket&) = delete;
  SOCKET get() const { return value_; }
  SOCKET release() { const SOCKET value = value_; value_ = INVALID_SOCKET; return value; }
 private:
  SOCKET value_;
};
const std::string* Text(const flutter::MethodCall<Value>& call, const char* key) {
  const auto* arguments = call.arguments();
  const auto* map = arguments ? std::get_if<Map>(arguments) : nullptr;
  if (!map) return nullptr;
  const auto it = map->find(Value(key));
  return it == map->end() ? nullptr : std::get_if<std::string>(&it->second);
}
std::optional<std::string> RandomState() {
  std::array<unsigned char, 32> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return std::nullopt;
  constexpr char hex[] = "0123456789abcdef";
  std::string result;
  result.reserve(bytes.size() * 2);
  for (const auto byte : bytes) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  SecureZeroMemory(bytes.data(), bytes.size());
  return result;
}
// Select uses a short bound so cancellation never waits for browser/network timeout.
int Readable(SOCKET socket) {
  fd_set descriptors;
  FD_ZERO(&descriptors);
  FD_SET(socket, &descriptors);
  timeval timeout{0, 100000};
  return select(0, &descriptors, nullptr, nullptr, &timeout);
}
std::optional<std::string> ReadRequest(SOCKET socket, const std::atomic<bool>& cancelled,
                                     Clock::time_point deadline) {
  std::string request;
  std::array<char, 2048> buffer{};
  const auto connection_deadline = (std::min)(deadline, Clock::now() + std::chrono::seconds(2));
  while (!cancelled.load() && Clock::now() < connection_deadline) {
    const int ready = Readable(socket);
    if (ready == SOCKET_ERROR) return std::nullopt;
    if (ready == 0) continue;
    const int count = recv(socket, buffer.data(), static_cast<int>(buffer.size()), 0);
    if (count == SOCKET_ERROR) {
      if (WSAGetLastError() == WSAEWOULDBLOCK) continue;
      return std::nullopt;
    }
    if (count <= 0) return std::nullopt;
    if (request.size() + static_cast<size_t>(count) > strava_oauth::kMaximumRequestBytes) return std::nullopt;
    request.append(buffer.data(), static_cast<size_t>(count));
    if (request.find("\r\n\r\n") != std::string::npos) return request;
  }
  return std::nullopt;
}
void ReplyToBrowser(SOCKET socket, bool completed) {
  const std::string body = completed
      ? "<!doctype html><meta charset=utf-8><title>HealthWorkoutExport</title><p>Authorization received. Return to HealthWorkoutExport.</p>"
      : "<!doctype html><meta charset=utf-8><title>HealthWorkoutExport</title><p>This request was not accepted.</p>";
  const std::string reply = std::string(completed ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 400 Bad Request\r\n") +
      "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
      "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n"
      "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
      "Connection: close\r\nContent-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
  // Nonblocking socket and fixed small response: never delay the Flutter completion
  // or repeat the authorization code in the browser response.
  static_cast<void>(send(socket, reply.data(), static_cast<int>(reply.size()), 0));
}
Outcome WaitForCallback(SOCKET raw_listener, uint16_t port, const std::string& state,
                        const std::atomic<bool>& cancelled, Clock::time_point deadline) {
  Socket listener(raw_listener);
  while (!cancelled.load() && Clock::now() < deadline) {
    const int ready = Readable(listener.get());
    if (ready == SOCKET_ERROR) return {"oauth_failed", "The local authorization listener failed", {}};
    if (ready == 0) continue;
    sockaddr_in peer{};
    int peer_size = static_cast<int>(sizeof(peer));
    Socket connection(accept(listener.get(), reinterpret_cast<sockaddr*>(&peer), &peer_size));
    if (connection.get() == INVALID_SOCKET) continue;
    if (peer.sin_family != AF_INET || peer.sin_addr.s_addr != htonl(INADDR_LOOPBACK)) continue;
    u_long nonblocking = 1;
    if (ioctlsocket(connection.get(), FIONBIO, &nonblocking) == SOCKET_ERROR) continue;
    const auto request = ReadRequest(connection.get(), cancelled, deadline);
    if (!request) continue;
    const auto callback = strava_oauth::ParseCallbackRequest(*request, port, state);
    ReplyToBrowser(connection.get(), callback.kind != strava_oauth::CallbackKind::kIgnore);
    switch (callback.kind) {
      case strava_oauth::CallbackKind::kAuthorized: return {{}, {}, callback.authorization_code};
      case strava_oauth::CallbackKind::kDenied: return {"oauth_cancelled", "Strava authorization was cancelled", {}};
      case strava_oauth::CallbackKind::kRejected: return {"oauth_failed", "Strava rejected the authorization request", {}};
      case strava_oauth::CallbackKind::kScopeDenied: return {"oauth_scope_denied", "Activity read and write permissions are required", {}};
      case strava_oauth::CallbackKind::kIgnore: break;  // Untrusted traffic must not cancel the real flow.
    }
  }
  if (cancelled.load()) return {"oauth_cancelled", "Strava authorization was cancelled", {}};
  return {"oauth_timeout", "Strava authorization timed out; please try again", {}};
}
}  // namespace

struct StravaOAuthPlugin::Implementation {
  explicit Implementation(HWND owner_window) : owner(owner_window) {
    WSADATA data{};
    winsock_ready = WSAStartup(MAKEWORD(2, 2), &data) == 0;
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = kWindowClass;
    if (RegisterClassW(&window_class) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS) {
      dispatch_window = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0,
                                        HWND_MESSAGE, nullptr, window_class.hInstance, this);
    }
  }
  ~Implementation() {
    cancelled.store(true);
    if (worker.joinable()) worker.join();
    if (dispatch_window) { KillTimer(dispatch_window, kDeadlineTimer); DestroyWindow(dispatch_window); }
    pending.reset();
    if (winsock_ready) WSACleanup();
  }
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<Implementation*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self && message == kCompleteMessage) {
      if (static_cast<uint64_t>(wparam) == self->generation) self->CompleteWorker();
      return 0;
    }
    if (self && message == WM_TIMER && wparam == kDeadlineTimer && self->pending &&
        Clock::now() >= self->deadline) {
      self->cancelled.store(true);
      if (self->worker.joinable()) self->worker.join();
      self->Finish({"oauth_timeout", "Strava authorization timed out; please try again", {}});
      return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }
  void Finish(Outcome outcome) {
    KillTimer(dispatch_window, kDeadlineTimer);
    if (worker.joinable()) worker.join();
    auto result = std::move(pending);
    if (!result) return;
    if (outcome.error.empty()) {
      if (owner) SetForegroundWindow(owner);
      result->Success(Value(outcome.authorization_code));
    } else result->Error(outcome.error, outcome.message);
  }
  void CompleteWorker() {
    std::optional<Outcome> outcome;
    { std::lock_guard<std::mutex> guard(completion_mutex); outcome = std::move(completion); completion.reset(); }
    if (outcome) {
      // A click on Cancel may arrive after the socket worker received a code but
      // before its UI message is processed. Never return that code after cancellation.
      if (cancelled.load()) Finish({"oauth_cancelled", "Strava authorization was cancelled", {}});
      else Finish(std::move(*outcome));
    }
  }
  void Authorize(const std::string& raw_url, const std::string& callback_scheme,
                 std::unique_ptr<Result> result) {
    if (pending) { result->Error("oauth_in_progress", "Strava authorization is already running"); return; }
    if (!winsock_ready || !dispatch_window) { result->Error("oauth_unavailable", "The local authorization receiver is unavailable"); return; }
    const auto state = RandomState();
    if (!state) { result->Error("oauth_configuration_error", "Secure authorization state could not be generated"); return; }
    Socket listener(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
    const BOOL exclusive = TRUE;
    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    local.sin_port = 0;
    int local_size = static_cast<int>(sizeof(local));
    u_long nonblocking = 1;
    if (listener.get() == INVALID_SOCKET ||
        setsockopt(listener.get(), SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), static_cast<int>(sizeof(exclusive))) == SOCKET_ERROR ||
        bind(listener.get(), reinterpret_cast<sockaddr*>(&local), static_cast<int>(sizeof(local))) == SOCKET_ERROR ||
        getsockname(listener.get(), reinterpret_cast<sockaddr*>(&local), &local_size) == SOCKET_ERROR ||
        ioctlsocket(listener.get(), FIONBIO, &nonblocking) == SOCKET_ERROR ||
        listen(listener.get(), 4) == SOCKET_ERROR) {
      result->Error("oauth_unavailable", "Could not reserve a private local authorization port"); return;
    }
    const uint16_t port = ntohs(local.sin_port);
    const auto url = strava_oauth::BuildAuthorizationUrl(raw_url, callback_scheme, *state, port);
    if (!url) { result->Error("invalid_arguments", "Strava authorization URL or callback scheme is invalid"); return; }
    pending = std::move(result);
    cancelled.store(false);
    ++generation;
    deadline = Clock::now() + std::chrono::seconds(strava_oauth::kTimeoutSeconds);
    { std::lock_guard<std::mutex> guard(completion_mutex); completion.reset(); }
    if (SetTimer(dispatch_window, kDeadlineTimer, strava_oauth::kTimeoutSeconds * 1000, nullptr) == 0) {
      Finish({"oauth_unavailable", "Authorization timeout tracking is unavailable", {}}); return;
    }
    const std::wstring wide_url(url->begin(), url->end());
    if (reinterpret_cast<INT_PTR>(ShellExecuteW(owner, L"open", wide_url.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) <= 32) {
      Finish({"oauth_failed", "Could not open the system browser", {}}); return;
    }
    const auto current_generation = generation;
    const SOCKET raw_listener = listener.release();
    try {
      worker = std::thread([this, raw_listener, port, state = *state, current_generation] {
        auto outcome = WaitForCallback(raw_listener, port, state, cancelled, deadline);
        { std::lock_guard<std::mutex> guard(completion_mutex); completion = std::move(outcome); }
        PostMessageW(dispatch_window, kCompleteMessage, static_cast<WPARAM>(current_generation), 0);
      });
    } catch (...) {
      closesocket(raw_listener);
      Finish({"oauth_failed", "Could not start the authorization receiver", {}});
    }
  }
  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
    if (call.method_name() == "cancelAuthorization") {
      const bool active = pending != nullptr;
      if (active) cancelled.store(true);
      result->Success(Value(active));
      return;
    }
    if (call.method_name() != "authorize") { result->NotImplemented(); return; }
    const auto* url = Text(call, "authorizationUrl");
    const auto* scheme = Text(call, "callbackScheme");
    if (!url || !scheme) { result->Error("invalid_arguments", "authorizationUrl and callbackScheme are required"); return; }
    Authorize(*url, *scheme, std::move(result));
  }
  HWND owner = nullptr;
  HWND dispatch_window = nullptr;
  bool winsock_ready = false;
  std::unique_ptr<Result> pending;
  std::thread worker;
  std::atomic<bool> cancelled{false};
  std::mutex completion_mutex;
  std::optional<Outcome> completion;
  uint64_t generation = 0;
  Clock::time_point deadline{};
};

StravaOAuthPlugin::StravaOAuthPlugin(HWND owner) : implementation_(std::make_unique<Implementation>(owner)) {}
StravaOAuthPlugin::~StravaOAuthPlugin() = default;
void StravaOAuthPlugin::Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
                              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  implementation_->Handle(call, std::move(result));
}
