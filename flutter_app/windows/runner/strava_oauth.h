#ifndef RUNNER_STRAVA_OAUTH_H_
#define RUNNER_STRAVA_OAUTH_H_

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <memory>

// Create, handle, and destroy on the Flutter platform/UI thread. The result stays
// owned until a validated callback, cancellation, or timeout completes the flow.
class StravaOAuthPlugin {
 public:
  explicit StravaOAuthPlugin(HWND owner);
  ~StravaOAuthPlugin();
  StravaOAuthPlugin(const StravaOAuthPlugin&) = delete;
  StravaOAuthPlugin& operator=(const StravaOAuthPlugin&) = delete;
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
 private:
  struct Implementation;
  std::unique_ptr<Implementation> implementation_;
};

#endif  // RUNNER_STRAVA_OAUTH_H_
