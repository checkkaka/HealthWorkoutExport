#ifndef RUNNER_STRAVA_WEB_PLUGIN_H_
#define RUNNER_STRAVA_WEB_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// Owns an isolated WebView2 profile. Cookies remain native; Flutter receives only
// readiness, bounded public response data and operation outcomes.
class StravaWebPlugin {
 public:
  using ProfileDirectory = std::function<bool(std::wstring*)>;
  StravaWebPlugin(HWND owner, ProfileDirectory profile_directory);
  ~StravaWebPlugin();
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
 private:
  struct Impl;
  std::shared_ptr<Impl> impl_;
};

#endif  // RUNNER_STRAVA_WEB_PLUGIN_H_
