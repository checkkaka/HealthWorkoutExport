#include "strava_web_plugin.h"

#include <WebView2.h>
#include <shellapi.h>
#include <winhttp.h>
#include <wrl.h>

#include <atomic>
#include <chrono>
#include <ctime>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>

#include "strava_web_protocol.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Call = flutter::MethodCall<Value>;
using Result = flutter::MethodResult<Value>;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Callback;
using Clock = std::chrono::steady_clock;
constexpr UINT kDispatchMessage = WM_APP + 0x482;
constexpr UINT_PTR kDeadlineTimer = 0x483;
constexpr wchar_t kWindowClass[] = L"HealthWorkoutExport.StravaWebView2";

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size, nullptr, nullptr);
  return result;
}
std::string ConsumeText(LPWSTR text) {
  const auto result = text ? Utf8(text) : std::string();
  CoTaskMemFree(text); return result;
}
const Value* Argument(const Call& call, const char* key) {
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (!args) return nullptr;
  const auto found = args->find(Value(key));
  return found == args->end() ? nullptr : &found->second;
}
std::string Text(const Call& call, const char* key) {
  const auto* value = Argument(call, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : std::string();
}
bool Integer(const Call& call, const char* key, int64_t* result) {
  const auto* value = Argument(call, key);
  if (!value) return false;
  if (const auto* number = std::get_if<int32_t>(value)) { *result = *number; return true; }
  if (const auto* number = std::get_if<int64_t>(value)) { *result = *number; return true; }
  return false;
}
std::string ListingPath(const Call& call) {
  int64_t page = 0, after = 0, before = 0;
  if (!Integer(call, "page", &page) || !Integer(call, "afterMs", &after) || !Integer(call, "beforeMs", &before)) return {};
  return strava_web::ActivityPagePath(page, after, before);
}
std::string Boundary() {
  GUID guid;
  wchar_t text[40] = {};
  if (FAILED(CoCreateGuid(&guid)) || StringFromGUID2(guid, text, 40) == 0) return {};
  std::string result = "Boundary-";
  for (const char c : Utf8(text)) if (c != '{' && c != '}') result += c;
  return result;
}
class InternetHandle {
 public:
  explicit InternetHandle(HINTERNET handle = nullptr) : handle_(handle) {}
  ~InternetHandle() { if (handle_) WinHttpCloseHandle(handle_); }
  InternetHandle(const InternetHandle&) = delete;
  InternetHandle& operator=(const InternetHandle&) = delete;
  HINTERNET get() const { return handle_; }
 private:
  HINTERNET handle_;
};

// No shared OS cookie jar, automatic authentication, redirect replay or TLS
// bypass. Blocking WinHTTP work runs off the Flutter/platform thread. Cancellation
// suppresses subsequent calls; an in-flight call remains bounded by OS timeouts.
class WinHttpTransport final : public strava_web::Transport {
 public:
  explicit WinHttpTransport(std::shared_ptr<std::atomic_bool> cancelled)
      : cancelled_(std::move(cancelled)), deadline_(Clock::now() + std::chrono::seconds(70)) {}
  strava_web::Response Execute(const strava_web::Request& input) override {
    strava_web::Response response;
    if (Stopped() || !strava_web::IsFixedRequestPath(input.path) || input.cookie.empty() || input.cookie.size() > strava_web::kMaxCookieBytes) return response;
    InternetHandle session(WinHttpOpen(L"HealthWorkoutExport/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
    if (!session.get() || !WinHttpSetTimeouts(session.get(), 10000, 10000, 10000, 10000)) return response;
    InternetHandle connection(WinHttpConnect(session.get(), L"www.strava.com", INTERNET_DEFAULT_HTTPS_PORT, 0));
    if (!connection.get()) return response;
    const auto method = Wide(input.method), path = Wide(input.path);
    InternetHandle request(WinHttpOpenRequest(connection.get(), method.c_str(), path.c_str(), nullptr,
      WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
    if (!request.get()) return response;
    DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
    if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled))) return response;
    DWORD decompression = WINHTTP_DECOMPRESSION_FLAG_GZIP | WINHTTP_DECOMPRESSION_FLAG_DEFLATE;
    if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_DECOMPRESSION, &decompression, sizeof(decompression))) return response;
    std::string headers = "Cookie: " + input.cookie + "\r\n";
    for (const auto& header : input.headers) {
      if (!strava_web::IsCookieName(header.first) || header.second.find_first_of("\r\n") != std::string::npos) return response;
      headers += header.first + ": " + header.second + "\r\n";
    }
    const auto wide_headers = Wide(headers);
    const size_t total = input.prefix.size() + (input.fit ? input.fit->size() : 0) + input.suffix.size();
    if (Stopped() || total > native_channels::kFitLimit + 16384 || !WinHttpSendRequest(request.get(),
        wide_headers.c_str(), static_cast<DWORD>(wide_headers.size()), WINHTTP_NO_REQUEST_DATA, 0, static_cast<DWORD>(total), 0)) return response;
    if (!Write(request.get(), reinterpret_cast<const uint8_t*>(input.prefix.data()), input.prefix.size()) ||
        (input.fit && !Write(request.get(), input.fit->data(), input.fit->size())) ||
        !Write(request.get(), reinterpret_cast<const uint8_t*>(input.suffix.data()), input.suffix.size()) ||
        Stopped() || !WinHttpReceiveResponse(request.get(), nullptr)) return response;
    DWORD status = 0, size = sizeof(status);
    if (!WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX)) return response;
    DWORD length = 0; size = sizeof(length);
    if (WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &length, &size, WINHTTP_NO_HEADER_INDEX) && length > strava_web::kMaxResponseBytes) return response;
    wchar_t location[2048] = {}; size = sizeof(location);
    if (WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_LOCATION, WINHTTP_HEADER_NAME_BY_INDEX,
        location, &size, WINHTTP_NO_HEADER_INDEX)) response.location = Utf8(location);
    char buffer[16384];
    while (!Stopped()) {
      DWORD received = 0;
      if (!WinHttpReadData(request.get(), buffer, sizeof(buffer), &received)) return {};
      if (received == 0) {
        response.status = static_cast<int>(status); response.received = true; return response;
      }
      if (response.body.size() + received > strava_web::kMaxResponseBytes) return {};
      response.body.append(buffer, received);
    }
    return {};
  }
 private:
  bool Stopped() const { return cancelled_->load() || Clock::now() >= deadline_; }
  bool Write(HINTERNET request, const uint8_t* bytes, size_t length) {
    for (size_t offset = 0; offset < length;) {
      DWORD written = 0;
      const auto count = static_cast<DWORD>(std::min<size_t>(16384, length - offset));
      if (Stopped() || !WinHttpWriteData(request, bytes + offset, count, &written) || written == 0) return false;
      offset += written;
    }
    return true;
  }
  std::shared_ptr<std::atomic_bool> cancelled_;
  Clock::time_point deadline_;
};
}  // namespace

struct StravaWebPlugin::Impl : public std::enable_shared_from_this<StravaWebPlugin::Impl> {
  enum class Mode { Idle, Login, Readiness, Clear, Upload, Delete, List, Speed };
  HWND owner = nullptr, window = nullptr;
  ProfileDirectory profile_directory;
  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> webview;
  ComPtr<ICoreWebView2CookieManager> cookies;
  std::unique_ptr<Result> result;
  std::shared_ptr<std::atomic_bool> cancelled;
  Mode mode = Mode::Idle;
  uint64_t generation = 0;
  bool alive = true, initializing = false, probe_running = false;
  Clock::time_point deadline;
  strava_web::Job job;
  std::mutex dispatch_mutex;
  std::deque<std::function<void()>> dispatched;

  Impl(HWND window_owner, ProfileDirectory directory) : owner(window_owner), profile_directory(std::move(directory)) {}
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    Impl* self = reinterpret_cast<Impl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      self = static_cast<Impl*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (!self) return DefWindowProcW(hwnd, message, wparam, lparam);
    if (message == WM_SIZE && self->controller) {
      RECT bounds; GetClientRect(hwnd, &bounds); self->controller->put_Bounds(bounds); return 0;
    }
    if (message == WM_CLOSE) {
      if (self->mode == Mode::Login) self->Fail("web_login_cancelled", "Strava web login was cancelled");
      ShowWindow(hwnd, SW_HIDE);
      if (self->webview) { self->webview->Stop(); self->webview->Navigate(L"about:blank"); }
      return 0;
    }
    if (message == kDispatchMessage) {
      std::deque<std::function<void()>> tasks;
      { std::lock_guard<std::mutex> lock(self->dispatch_mutex); tasks.swap(self->dispatched); }
      for (auto& task : tasks) task();
      return 0;
    }
    if (message == WM_TIMER && wparam == kDeadlineTimer) {
      if (self->mode != Mode::Idle && Clock::now() >= self->deadline) {
        if (self->mode == Mode::Readiness) self->Finish(Value(false));
        else self->Fail(self->mode == Mode::Login ? "web_login_timeout" : "web_operation_timeout", "Strava web operation timed out", self->mode == Mode::Upload || self->mode == Mode::Delete);
        if (self->webview) self->webview->Stop();
      }
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
  bool CreateHost() {
    if (window) return true;
    WNDCLASSW type = {};
    type.lpfnWndProc = WindowProc;
    type.hInstance = GetModuleHandleW(nullptr);
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.lpszClassName = kWindowClass;
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    window = CreateWindowExW(0, kWindowClass, L"Log in to Strava", WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, 1000, 760, owner, nullptr, type.hInstance, this);
    return window != nullptr;
  }
  void Queue(std::function<void()> task) {
    std::lock_guard<std::mutex> lock(dispatch_mutex);
    if (!alive || !window) return;
    dispatched.push_back(std::move(task));
    PostMessageW(window, kDispatchMessage, 0, 0);
  }
  bool Current(uint64_t id) const { return alive && result && generation == id; }
  void Finish(const Value& value = Value()) {
    if (!result) return;
    if (cancelled) cancelled->store(true);
    auto pending = std::move(result);
    mode = Mode::Idle; probe_running = false; ++generation;
    if (window) { KillTimer(window, kDeadlineTimer); ShowWindow(window, SW_HIDE); }
    job = {};
    pending->Success(value);
  }
  void Fail(const std::string& code, const std::string& message, bool possibly_mutated = false) {
    if (!result) return;
    const auto prior_mode = mode;
    if (cancelled) cancelled->store(true);
    auto pending = std::move(result);
    mode = Mode::Idle; probe_running = false; ++generation;
    if (window) { KillTimer(window, kDeadlineTimer); ShowWindow(window, SW_HIDE); }
    job = {};
    Map detail{{Value("retryable"), Value(!possibly_mutated)}};
    if (possibly_mutated && prior_mode == Mode::Upload) detail[Value("mayHaveUploaded")] = Value(true);
    if (possibly_mutated && prior_mode == Mode::Delete) detail[Value("mayHaveDeleted")] = Value(true);
    pending->Error(code, message, Value(detail));
  }
  void Shutdown() {
    if (result) Fail("web_operation_interrupted", "Strava web operation was interrupted; check the activity before retrying", mode == Mode::Upload || mode == Mode::Delete);
    { std::lock_guard<std::mutex> lock(dispatch_mutex); alive = false; dispatched.clear(); }
    if (controller) controller->Close();
    cookies.Reset(); webview.Reset(); controller.Reset(); environment.Reset();
    if (window) { SetWindowLongPtrW(window, GWLP_USERDATA, 0); DestroyWindow(window); window = nullptr; }
  }
  void InitializationFailed() {
    initializing = false;
    if (mode == Mode::Readiness) Finish(Value(false));
    else Fail("webview2_unavailable", "Microsoft Edge WebView2 Runtime is required. Install the official Evergreen Runtime from https://developer.microsoft.com/microsoft-edge/webview2/");
  }
  void Ensure() {
    if (webview && cookies) { Start(); return; }
    if (initializing) return;
    if (!CreateHost()) { Fail("web_window_failed", "Windows could not create the Strava login window"); return; }
    SetTimer(window, kDeadlineTimer, 1000, nullptr);
    std::wstring profile;
    if (!profile_directory(&profile)) { Fail("web_profile_protected", "The private WebView2 profile is inaccessible"); return; }
    initializing = true;
    const std::weak_ptr<Impl> weak = shared_from_this();
    const HRESULT status = CreateCoreWebView2EnvironmentWithOptions(nullptr, profile.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>([weak](HRESULT code, ICoreWebView2Environment* created) -> HRESULT {
        const auto self = weak.lock();
        if (!self || !self->alive) return S_OK;
        if (FAILED(code) || !created) { self->InitializationFailed(); return S_OK; }
        self->environment = created;
        const HRESULT controller_status = created->CreateCoreWebView2Controller(self->window,
          Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>([weak](HRESULT controller_code, ICoreWebView2Controller* created_controller) -> HRESULT {
            const auto active = weak.lock();
            if (!active || !active->alive) { if (created_controller) created_controller->Close(); return S_OK; }
            if (FAILED(controller_code) || !created_controller) { active->InitializationFailed(); return S_OK; }
            active->controller = created_controller;
            if (FAILED(created_controller->get_CoreWebView2(active->webview.GetAddressOf())) || !active->Configure()) {
              active->controller->Close(); active->controller.Reset(); active->webview.Reset(); active->cookies.Reset();
              active->InitializationFailed(); return S_OK;
            }
            RECT bounds; GetClientRect(active->window, &bounds); active->controller->put_Bounds(bounds);
            active->initializing = false;
            if (active->result) active->Start();
            return S_OK;
          }).Get());
        if (FAILED(controller_status)) self->InitializationFailed();
        return S_OK;
      }).Get());
    if (FAILED(status)) InitializationFailed();
  }
  bool Configure() {
    ComPtr<ICoreWebView2_2> version2;
    ComPtr<ICoreWebView2Settings> settings;
    ComPtr<ICoreWebView2Settings4> settings4;
    if (FAILED(webview.As(&version2)) || FAILED(version2->get_CookieManager(cookies.GetAddressOf())) ||
        FAILED(webview->get_Settings(settings.GetAddressOf())) || FAILED(settings.As(&settings4))) return false;
    if (FAILED(settings->put_AreDevToolsEnabled(FALSE)) || FAILED(settings->put_IsWebMessageEnabled(FALSE)) ||
        FAILED(settings->put_AreHostObjectsAllowed(FALSE)) || FAILED(settings4->put_IsPasswordAutosaveEnabled(FALSE)) ||
        FAILED(settings4->put_IsGeneralAutofillEnabled(FALSE))) return false;
    const std::weak_ptr<Impl> weak = shared_from_this();
    EventRegistrationToken registration;
    if (FAILED(webview->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
          const auto self = weak.lock(); if (!self || !self->alive) { args->put_Cancel(TRUE); return S_OK; }
          LPWSTR raw = nullptr; args->get_Uri(&raw); const auto uri = ConsumeText(raw);
          if (uri != "about:blank" && !strava_web::IsAllowedLoginUrl(uri)) args->put_Cancel(TRUE);
          return S_OK;
        }).Get(), &registration))) return false;
    if (FAILED(webview->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
          args->put_Handled(TRUE);
          const auto self = weak.lock(); if (!self || !self->alive) return S_OK;
          LPWSTR raw = nullptr; args->get_Uri(&raw); const auto uri = ConsumeText(raw);
          if (self->mode == Mode::Login && strava_web::IsAllowedLoginUrl(uri)) self->webview->Navigate(Wide(uri).c_str());
          return S_OK;
        }).Get(), &registration))) return false;
    if (FAILED(webview->add_PermissionRequested(Callback<ICoreWebView2PermissionRequestedEventHandler>(
        [](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
          return args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
        }).Get(), &registration))) return false;
    if (FAILED(webview->add_ProcessFailed(Callback<ICoreWebView2ProcessFailedEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs*) -> HRESULT {
          const auto self = weak.lock();
          if (self && self->alive) {
            if (self->result) self->Fail("web_process_failed", "The Strava login browser was interrupted", self->mode == Mode::Upload || self->mode == Mode::Delete);
            if (self->controller) self->controller->Close();
            self->cookies.Reset(); self->webview.Reset(); self->controller.Reset(); self->environment.Reset();
            self->initializing = false;
          }
          return S_OK;
        }).Get(), &registration))) return false;
    if (FAILED(webview->add_NavigationCompleted(Callback<ICoreWebView2NavigationCompletedEventHandler>(
        [weak](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
          const auto self = weak.lock(); if (!self || !self->alive || !self->result) return S_OK;
          BOOL success = FALSE; args->get_IsSuccess(&success);
          LPWSTR raw = nullptr; self->webview->get_Source(&raw); const auto source = ConsumeText(raw);
          if (self->mode == Mode::Clear && source == "about:blank" && success) { self->Clear(); return S_OK; }
          strava_web::HttpsUrl parsed;
          if (self->mode == Mode::Login && success && !self->probe_running && strava_web::ParseHttpsUrl(source, &parsed) &&
              (parsed.host == "www.strava.com" || parsed.host == "strava.com") && parsed.path != "/login" && parsed.path != "/register") {
            self->probe_running = true; self->Capture({"/athlete/training_activities"});
          }
          return S_OK;
        }).Get(), &registration))) return false;
    ComPtr<ICoreWebView2_4> version4;
    if (SUCCEEDED(webview.As(&version4))) {
      if (FAILED(version4->add_DownloadStarting(Callback<ICoreWebView2DownloadStartingEventHandler>(
          [](ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT { return args->put_Cancel(TRUE); }
        ).Get(), &registration))) return false;
    }
    return true;
  }
  void Start() {
    if (!result) return;
    SetTimer(window, kDeadlineTimer, 1000, nullptr);
    if (mode == Mode::Login) {
      ShowWindow(window, SW_SHOW); SetForegroundWindow(window);
      controller->put_IsVisible(TRUE);
      if (FAILED(webview->Navigate(L"https://www.strava.com/login"))) Fail("web_login_failed", "The Strava login page could not be opened");
      return;
    }
    if (mode == Mode::Clear) {
      webview->Stop();
      if (FAILED(webview->Navigate(L"about:blank"))) Fail("web_cookie_clear_failed", "The Strava login page could not be closed");
      return;
    }
    std::vector<std::string> paths;
    if (mode == Mode::Readiness || mode == Mode::List) paths = {"/athlete/training_activities"};
    if (mode == Mode::Upload) paths = {"/about", "/upload/select", "/upload/files"};
    if (mode == Mode::Delete) paths = {"/activities/" + job.remote_id, "/about", "/upload/select"};
    if (mode == Mode::Speed) paths = {"/activities/" + job.remote_id, "/activities/" + job.remote_id + "/streams"};
    Capture(std::move(paths));
  }
  void Clear() {
    if (FAILED(cookies->DeleteAllCookies())) { Fail("web_cookie_clear_failed", "Strava cookies could not be cleared"); return; }
    const std::weak_ptr<Impl> weak = shared_from_this(); const auto id = generation;
    if (FAILED(cookies->GetCookies(L"", Callback<ICoreWebView2GetCookiesCompletedHandler>(
        [weak, id](HRESULT code, ICoreWebView2CookieList* list) -> HRESULT {
          const auto self = weak.lock(); if (!self || !self->Current(id)) return S_OK;
          UINT count = 0;
          if (FAILED(code) || !list || FAILED(list->get_Count(&count)) || count != 0) self->Fail("web_cookie_clear_failed", "Cookie clearing could not be verified");
          else self->Finish();
          return S_OK;
        }).Get()))) Fail("web_cookie_clear_failed", "Cookie clearing could not be verified");
  }
  void Capture(std::vector<std::string> paths, size_t index = 0) {
    if (!result) return;
    if (index == paths.size()) { Run(); return; }
    const auto path = paths[index];
    if (!strava_web::IsFixedRequestPath(path)) { Fail("invalid_arguments", "Invalid Strava request path"); return; }
    const std::weak_ptr<Impl> weak = shared_from_this(); const auto id = generation;
    const auto uri = Wide(std::string(strava_web::kOrigin) + path);
    if (FAILED(cookies->GetCookies(uri.c_str(), Callback<ICoreWebView2GetCookiesCompletedHandler>(
        [weak, id, paths, index, path](HRESULT code, ICoreWebView2CookieList* list) -> HRESULT {
          const auto self = weak.lock(); if (!self || !self->Current(id)) return S_OK;
          UINT count = 0;
          if (FAILED(code) || !list || FAILED(list->get_Count(&count)) || count > 512) {
            self->Fail("web_cookie_read_failed", "Strava cookies could not be read"); return S_OK;
          }
          std::vector<strava_web::Cookie> values;
          for (UINT i = 0; i < count; ++i) {
            ComPtr<ICoreWebView2Cookie> cookie;
            if (FAILED(list->GetValueAtIndex(i, cookie.GetAddressOf()))) continue;
            LPWSTR name = nullptr, value = nullptr, domain = nullptr, cookie_path = nullptr;
            double expires = 0; BOOL session = FALSE;
            const bool valid = SUCCEEDED(cookie->get_Name(&name)) && SUCCEEDED(cookie->get_Value(&value)) &&
              SUCCEEDED(cookie->get_Domain(&domain)) && SUCCEEDED(cookie->get_Path(&cookie_path)) &&
              SUCCEEDED(cookie->get_Expires(&expires)) && SUCCEEDED(cookie->get_IsSession(&session));
            strava_web::Cookie entry{ConsumeText(name), ConsumeText(value), ConsumeText(domain), ConsumeText(cookie_path), expires, session != FALSE};
            if (valid) values.push_back(std::move(entry));
          }
          self->job.cookies[path] = strava_web::CookieHeader(values, path, static_cast<double>(std::time(nullptr)));
          self->Capture(paths, index + 1);
          return S_OK;
        }).Get()))) Fail("web_cookie_read_failed", "Strava cookies could not be read");
  }
  void Run() {
    if (!result) return;
    if (mode == Mode::Readiness || mode == Mode::Login) job.operation = strava_web::Operation::Probe;
    if (job.cookies.empty() || std::all_of(job.cookies.begin(), job.cookies.end(), [](const auto& entry) { return entry.second.empty(); })) {
      if (mode == Mode::Readiness) Finish(Value(false));
      else if (mode == Mode::Login) { probe_running = false; SetWindowTextW(window, L"Finish signing in to Strava"); }
      else Fail("web_not_ready", "Strava web login has expired; sign in again");
      return;
    }
    const std::weak_ptr<Impl> weak = shared_from_this(); const auto id = generation;
    const auto token = cancelled;
    auto work = std::make_shared<strava_web::Job>(std::move(job));
    std::thread([weak, id, token, work]() {
      WinHttpTransport transport(token);
      auto outcome = strava_web::Perform(&transport, *work);
      if (token->load()) return;
      if (const auto self = weak.lock()) self->Queue([weak, id, outcome = std::move(outcome)]() {
        const auto active = weak.lock(); if (!active || !active->Current(id)) return;
        active->Complete(outcome);
      });
    }).detach();
  }
  void Complete(const strava_web::Outcome& outcome) {
    if (mode == Mode::Login) {
      probe_running = false;
      if (outcome.ready) Finish(Value(true));
      else SetWindowTextW(window, L"Login not verified. Finish signing in, or close to cancel");
      return;
    }
    if (mode == Mode::Readiness) { Finish(Value(outcome.ready)); return; }
    if (!outcome.success) {
      const auto code = mode == Mode::Upload ? "web_upload_failed" : mode == Mode::Delete ? "web_delete_failed" : "web_list_failed";
      Fail(code, outcome.may_have_mutated ? "Strava did not confirm the operation; check the activity before retrying" : "The Strava web session could not complete the request; sign in again", outcome.may_have_mutated);
      return;
    }
    if (mode == Mode::Upload) {
      Map payload{{Value("isDuplicate"), Value(outcome.duplicate)}};
      if (!outcome.remote_id.empty()) payload[Value("remoteId")] = Value(outcome.remote_id);
      Finish(Value(payload)); return;
    }
    if (mode == Mode::List) { Finish(Value(outcome.json)); return; }
    if (mode == Mode::Speed && !outcome.missing) {
      Map payload{{Value("pageHtml"), Value(outcome.page_html)}};
      if (!outcome.streams_json.empty()) payload[Value("streamsJson")] = Value(outcome.streams_json);
      Finish(Value(payload)); return;
    }
    Finish();
  }
  void Handle(const Call& call, std::unique_ptr<Result> incoming) {
    if (call.method_name() == "openActivity") {
      const auto id = Text(call, "remoteId");
      if (!native_channels::IsActivityId(id)) { incoming->Error("invalid_arguments", "A numeric Strava activity ID is required"); return; }
      const auto url = Wide(std::string(strava_web::kOrigin) + "/activities/" + id);
      if (reinterpret_cast<INT_PTR>(ShellExecuteW(owner, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) <= 32) incoming->Error("open_activity_failed", "Windows could not open the Strava activity");
      else incoming->Success();
      return;
    }
    Mode requested = Mode::Idle;
    if (call.method_name() == "login") requested = Mode::Login;
    else if (call.method_name() == "hasCookie") requested = Mode::Readiness;
    else if (call.method_name() == "clearCookies") requested = Mode::Clear;
    else if (call.method_name() == "uploadFit") requested = Mode::Upload;
    else if (call.method_name() == "deleteActivity") requested = Mode::Delete;
    else if (call.method_name() == "listActivityPage") requested = Mode::List;
    else if (call.method_name() == "readActivitySpeedData") requested = Mode::Speed;
    else { incoming->NotImplemented(); return; }
    if (result) { incoming->Error("web_operation_in_progress", "Another Strava web operation is in progress"); return; }
    strava_web::Job next;
    if (requested == Mode::Upload) {
      next.operation = strava_web::Operation::Upload;
      next.filename = Text(call, "filename"); next.boundary = Boundary();
      const auto* value = Argument(call, "data");
      const auto* bytes = value ? std::get_if<strava_web::Bytes>(value) : nullptr;
      if (!bytes || bytes->empty() || bytes->size() > native_channels::kFitLimit || !strava_web::IsSafeFilename(next.filename) || next.boundary.empty()) {
        incoming->Error("invalid_arguments", "Upload requires bounded FIT bytes and a safe filename"); return;
      }
      next.fit = *bytes;
    }
    if (requested == Mode::Delete || requested == Mode::Speed) {
      next.operation = requested == Mode::Delete ? strava_web::Operation::Delete : strava_web::Operation::Speed;
      next.remote_id = Text(call, "remoteId");
      if (!native_channels::IsActivityId(next.remote_id)) { incoming->Error("invalid_arguments", "A numeric Strava activity ID is required"); return; }
    }
    if (requested == Mode::List) {
      next.operation = strava_web::Operation::List; next.listing_path = ListingPath(call);
      if (next.listing_path.empty()) { incoming->Error("invalid_arguments", "Listing requires a valid page and bounded date interval"); return; }
    }
    mode = requested; job = std::move(next); result = std::move(incoming); ++generation;
    cancelled = std::make_shared<std::atomic_bool>(false);
    deadline = Clock::now() + (mode == Mode::Login ? std::chrono::seconds(600) : std::chrono::seconds(85));
    Ensure();
  }
};

StravaWebPlugin::StravaWebPlugin(HWND owner, ProfileDirectory directory)
    : impl_(std::make_shared<Impl>(owner, std::move(directory))) {}
StravaWebPlugin::~StravaWebPlugin() { impl_->Shutdown(); }
void StravaWebPlugin::Handle(const Call& call, std::unique_ptr<Result> result) { impl_->Handle(call, std::move(result)); }
