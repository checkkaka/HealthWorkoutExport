#ifndef RUNNER_NATIVE_CHANNELS_H_
#define RUNNER_NATIVE_CHANNELS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <vector>

class StravaWebPlugin;
class StravaOAuthPlugin;

// Owned by FlutterWindow; handlers are removed before the engine is destroyed.
class NativeChannels {
 public:
  NativeChannels(flutter::BinaryMessenger* messenger, HWND window);
  ~NativeChannels();
  NativeChannels(const NativeChannels&) = delete;
  NativeChannels& operator=(const NativeChannels&) = delete;
 private:
  HWND window_;
  bool picker_open_ = false;
  std::unique_ptr<StravaWebPlugin> web_plugin_;
  std::unique_ptr<StravaOAuthPlugin> oauth_plugin_;
  std::vector<std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>> channels_;
};

#endif  // RUNNER_NATIVE_CHANNELS_H_
