#include "../runner/native_channel_validation.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>

namespace {
size_t assertions = 0;
void Check(bool condition, const char* description) {
  ++assertions;
  if (!condition) { std::cerr << "FAIL: " << description << '\n'; std::exit(1); }
}
bool Json(const std::string& value) {
  return native_channels::IsJsonObject(std::vector<uint8_t>(value.begin(), value.end()));
}
}

int main() {
  using namespace native_channels;
  for (const auto* method : {"readHealthPreparedFit", "writeHealthPreparedFit", "deleteHealthPreparedFit"})
    Check(IsHealthPreparedFitMethod(method), "health preparation method is recognized separately");
  Check(!IsHealthPreparedFitMethod("readSyncedFit"), "uploaded archive is not health preparation");
  Check(IsFingerprint(std::string(64, 'a')), "lowercase fingerprint accepted");
  Check(IsFingerprint(std::string(64, '0')), "numeric fingerprint accepted");
  for (const auto& value : {std::string(), std::string(63, 'a'), std::string(65, 'a'),
                           std::string(64, 'A'), std::string(64, 'g'), "../" + std::string(61, 'a'),
                           "C:\\" + std::string(61, 'a'), std::string(63, 'a') + "\n"})
    Check(!IsFingerprint(value), "invalid fingerprint rejected");
  Check(IsActivityId("1234567890"), "activity ID accepted");
  Check(IsActivityId(std::string(32, '9')), "32 digit activity ID accepted");
  for (const auto& value : {"", "-1", "1/../../settings", "https://example.com", "1?token=secret", "1\n", "１２３"})
    Check(!IsActivityId(value), "activity URL injection rejected");
  Check(!IsActivityId(std::string(33, '1')), "oversized activity ID rejected");
  for (const auto& key : {"strava.uploadMode", "strava.gcjCorrectionEnabled", "virtualPower.enabled",
                         "virtualPower.includeInertia", "virtualPower.riderMassKg", "virtualPower.bikeMassKg", "virtualPower.cda", "sync_preview_policy", "write_to_apple_health"})
    Check(IsPreferenceKey(key), "preference allowlist accepts known key");
  for (const auto& key : {"", "strava.clientSecret", "strava.accessToken", "onelap.refresh", "../sync_state.json", "STRAVA.uploadMode"})
    Check(!IsPreferenceKey(key), "credentials and arbitrary preference paths rejected");
  Check(IsNonEmptyText(" a "), "credential whitespace preserved");
  Check(!IsNonEmptyText(" \t\n"), "whitespace-only credential rejected");
  Check(!IsNonEmptyText(std::string("a\0b", 3)), "NUL credential rejected");
  Check(!IsNonEmptyText(std::string(kCredentialLimit + 1, 'a')), "oversized credential rejected");
  Check(IsUtf8("训练🚲"), "valid UTF-8 accepted");
  for (const auto& value : {std::string("\xc0\xaf", 2), std::string("\xe0\x80\xaf", 3),
                           std::string("\xed\xa0\x80", 3), std::string("\xf4\x90\x80\x80", 4),
                           std::string("\xff", 1), std::string("\xe4\xb8", 2)})
    Check(!IsUtf8(value), "invalid UTF-8 rejected");
  for (const auto& value : {"{}", " \n{\"a\":[]}\t", "{\"a\":null,\"b\":true,\"c\":false}",
                           "{\"number\":-0.031e+12}", "{\"a\":{\"b\":[1,2,\"训练🚲\"]}}",
                           "{\"escapes\":\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0011\\uD83D\\uDEB2\"}"})
    Check(Json(value), "JSON object accepted");
  for (const auto& value : {"", "[]", "null", "true", "1", "{", "{\"a\":}", "{\"a\":01}",
                           "{\"a\":NaN}", "{\"a\":Infinity}", "{\"a\":1.}", "{\"a\":1e}",
                           "{\"a\":+1}", "{\"a\":1,}", "{\"a\":[1,]}", "{}{}", "{}junk",
                           "{\"a\":\"\\x01\"}", "{\"a\":\"\\uD800\"}", "{\"a\":\"\\uDC00\"}",
                           "{\"a\":\"\\uD800\\u0020\"}", "{\"a\":\"\n\"}", "{a:1}"})
    Check(!Json(value), "malformed JSON rejected");
  Check(!Json(std::string("{\"a\":\"") + std::string("\xc0\xaf", 2) + "\"}"), "invalid UTF-8 JSON rejected");
  Check(!Json(std::string("{}\0", 3)), "embedded NUL JSON rejected");
  Check(!Json("{\"a\":" + std::string(129, '[') + "0" + std::string(129, ']') + "}"), "deep nesting bounded");
  Check(Json("{\"a\":" + std::string(100, '[') + "0" + std::string(100, ']') + "}"), "normal nested JSON accepted");

  for (const Scalar& scalar : {Scalar(true), Scalar(false), Scalar(int64_t(-123)),
      Scalar(std::numeric_limits<int64_t>::min()), Scalar(std::numeric_limits<int64_t>::max()),
      Scalar(0.32), Scalar(1.2345678901234567), Scalar(std::numeric_limits<double>::min()),
      Scalar(std::string()), Scalar(std::string("训练")), Scalar(std::string("x\0y", 3))}) {
    std::vector<uint8_t> bytes;
    Scalar restored;
    Check(EncodeScalar(scalar, &bytes), "preference scalar encodes");
    Check(DecodeScalar(bytes, &restored) && scalar == restored, "preference scalar round-trips without precision loss");
    if (bytes[4] != 2) {
      bytes.pop_back();
      Check(!DecodeScalar(bytes, &restored), "truncated scalar rejected");
    }
  }
  std::vector<uint8_t> scalar_bytes;
  Scalar scalar;
  Check(!EncodeScalar(std::numeric_limits<double>::infinity(), &scalar_bytes), "infinite preference rejected");
  Check(!EncodeScalar(std::numeric_limits<double>::quiet_NaN(), &scalar_bytes), "NaN preference rejected");
  Check(!EncodeScalar(std::string(kPreferenceLimit, 'a'), &scalar_bytes), "oversized preference rejected");
  Check(!EncodeScalar(std::string("\xff", 1), &scalar_bytes), "invalid UTF-8 preference rejected");
  Check(!DecodeScalar({'H', 'W', 'P', 1, 1, 2}, &scalar), "invalid boolean rejected");
  Check(!DecodeScalar({'H', 'W', 'P', 1, 99}, &scalar), "unsupported preference tag rejected");
  Check(!DecodeScalar({'H', 'W', 'P', 1, 4, 0, 0, 0, 0, 0, 0, 0xf0, 0x7f}, &scalar), "stored infinite preference rejected");

  SecretMap source{{"onelap.account", "test-account"}, {"onelap.password", "synthetic-only"},
                   {"onelap.token", "test-token"}, {"onelap.uid", "42"}, {"onelap.refresh", "test-refresh"}};
  std::vector<uint8_t> encoded;
  SecretMap decoded;
  Check(EncodeSecrets(source, &encoded), "synthetic credential map encodes");
  Check(DecodeSecrets(encoded, &decoded) && decoded == source, "credential fields round-trip including legacy onelap.refresh");
  for (size_t size = 0; size < encoded.size(); ++size) {
    // A prefix at a complete field boundary is a valid partial vault. Truncating
    // within a field must fail without over-reading; incomplete leases fail closed.
    const std::vector<uint8_t> prefix(encoded.begin(), encoded.begin() + size);
    if (DecodeSecrets(prefix, &decoded)) {
      for (const auto& entry : decoded) Check(source.at(entry.first) == entry.second, "accepted prefix contains only complete fields");
    }
  }
  auto invalid = encoded;
  invalid[3] = 2;
  Check(!DecodeSecrets(invalid, &decoded), "unknown credential version rejected");
  invalid = encoded;
  invalid[5] = 0xff; invalid[6] = 0xff;
  Check(!DecodeSecrets(invalid, &decoded), "credential length overflow rejected");
  invalid = encoded;
  invalid.insert(invalid.end(), encoded.begin() + 4, encoded.end());
  Check(!DecodeSecrets(invalid, &decoded), "duplicate credential fields rejected");
  Check(!EncodeSecrets({{"onelap.token", std::string(kCredentialLimit, 'x')}}, &encoded), "whole credential record is bounded");
  Check(!DecodeSecrets(std::vector<uint8_t>(kCredentialLimit + 1), &decoded), "oversized stored credential rejected");
  Check(!EncodeSecrets({{"key", ""}}, &encoded), "empty credential rejected");
  Check(!EncodeSecrets({{"key", std::string("\xff", 1)}}, &encoded), "non UTF-8 credential rejected");
  Check(kStateLimit == 16 * 1024 * 1024 && kFitLimit == 64 * 1024 * 1024 && kRecoveryLimit == 90 * 1024 * 1024,
        "storage limits match platform contract");
  std::cout << assertions << " native validation assertions passed\n";
  return 0;
}
