#include "../runner/strava_oauth.h"
#include "../runner/strava_web_plugin.h"

#include <iostream>
#include <string>

namespace {
using Value = flutter::EncodableValue;
using Call = flutter::MethodCall<Value>;
struct Response { int count = 0; std::string code; };
class TestResult final : public flutter::MethodResult<Value> {
 public:
  explicit TestResult(Response* response) : response_(response) {}
 private:
  void SuccessInternal(const Value*) override { ++response_->count; response_->code = "success"; }
  void ErrorInternal(const std::string& code, const std::string&, const Value*) override { ++response_->count; response_->code = code; }
  void NotImplementedInternal() override { ++response_->count; response_->code = "not_implemented"; }
  Response* response_;
};
}
int main() {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com)) return 1;
  bool passed = true;
  {
    // Invalid-input dispatch/link smoke tests only: never initialize a WebView,
    // read real cookies, bind an OAuth socket, or contact an external service.
    bool requested_profile = false;
    StravaWebPlugin web(GetDesktopWindow(), [&requested_profile](std::wstring*) { requested_profile = true; return false; });
    StravaOAuthPlugin oauth(GetDesktopWindow());
    for (const auto* method : {"uploadFit", "deleteActivity", "listActivityPage", "readActivitySpeedData", "openActivity"}) {
      Response response;
      web.Handle(Call(method, nullptr), std::make_unique<TestResult>(&response));
      passed = passed && response.count == 1 && response.code == "invalid_arguments";
    }
    Response authorization;
    oauth.Handle(Call("authorize", nullptr), std::make_unique<TestResult>(&authorization));
    passed = passed && authorization.count == 1 && authorization.code == "invalid_arguments";
    Response unknown;
    web.Handle(Call("notAnOperation", nullptr), std::make_unique<TestResult>(&unknown));
    passed = passed && unknown.count == 1 && unknown.code == "not_implemented" && !requested_profile;
  }
  CoUninitialize();
  if (!passed) { std::cerr << "Windows asynchronous adapter input checks failed\n"; return 1; }
  std::cout << "Windows asynchronous adapters linked; invalid-input checks passed without network or credentials\n";
  return 0;
}
