#ifndef RUNNER_NATIVE_CHANNEL_VALIDATION_H_
#define RUNNER_NATIVE_CHANNEL_VALIDATION_H_

#include <algorithm>
#include <cmath>
#include <cstring>
#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

// Pure, bounded input checks shared by the Win32 adapters and portable tests.
namespace native_channels {
inline constexpr size_t kStateLimit = 16 * 1024 * 1024;
inline constexpr size_t kFitLimit = 64 * 1024 * 1024;
inline constexpr size_t kRecoveryLimit = 90 * 1024 * 1024;
inline constexpr size_t kPreferenceLimit = 4096;
inline constexpr size_t kCredentialLimit = 2560;

inline bool IsFingerprint(std::string_view value) {
  return value.size() == 64 && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
inline bool IsActivityId(std::string_view value) {
  return !value.empty() && value.size() <= 32 &&
         std::all_of(value.begin(), value.end(), [](char c) { return c >= '0' && c <= '9'; });
}
inline bool IsPreferenceKey(std::string_view key) {
  return key == "strava.uploadMode" || key == "strava.gcjCorrectionEnabled" ||
         key == "virtualPower.enabled" || key == "virtualPower.includeInertia" ||
         key == "virtualPower.riderMassKg" || key == "virtualPower.bikeMassKg" ||
         key == "virtualPower.cda";
}
inline bool IsNonEmptyText(std::string_view value) {
  return !value.empty() && value.size() <= kCredentialLimit &&
         value.find('\0') == std::string_view::npos &&
         value.find_first_not_of(" \t\r\n") != std::string_view::npos;
}
inline bool IsUtf8(std::string_view value) {
  size_t i = 0;
  while (i < value.size()) {
    const auto first = static_cast<uint8_t>(value[i++]);
    if (first < 0x80) continue;
    unsigned count = 0;
    uint32_t codepoint = 0;
    uint32_t minimum = 0;
    if (first >= 0xc2 && first <= 0xdf) { count = 1; codepoint = first & 0x1f; minimum = 0x80; }
    else if (first >= 0xe0 && first <= 0xef) { count = 2; codepoint = first & 0x0f; minimum = 0x800; }
    else if (first >= 0xf0 && first <= 0xf4) { count = 3; codepoint = first & 0x07; minimum = 0x10000; }
    else return false;
    if (count > value.size() - i) return false;
    for (unsigned j = 0; j < count; ++j) {
      const auto next = static_cast<uint8_t>(value[i++]);
      if ((next & 0xc0) != 0x80) return false;
      codepoint = (codepoint << 6) | (next & 0x3f);
    }
    if (codepoint < minimum || codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff)) return false;
  }
  return true;
}

// Syntax-only JSON validator. Rust still owns schema/business validation. This
// rejects invalid UTF-8, trailing data and deeply nested input without allocating
// a second 90 MiB recovery object or trusting an unbounded JSON decoder.
class JsonValidator {
 public:
  explicit JsonValidator(std::string_view input) : input_(input) {}
  bool Object() { return Validate(false); }
  bool Collection() { return Validate(true); }
 private:
  bool Validate(bool allow_array) {
    if (!IsUtf8(input_)) return false;
    Space();
    if ((Peek() != '{' && !(allow_array && Peek() == '[')) || !Value(0)) return false;
    Space();
    return offset_ == input_.size();
  }
 public:
 private:
  char Peek() const { return offset_ < input_.size() ? input_[offset_] : '\0'; }
  bool Take(char c) { if (Peek() != c) return false; ++offset_; return true; }
  void Space() { while (Peek() == ' ' || Peek() == '\t' || Peek() == '\r' || Peek() == '\n') ++offset_; }
  bool Literal(std::string_view text) {
    if (input_.substr(offset_, text.size()) != text) return false;
    offset_ += text.size(); return true;
  }
  bool Hex(uint32_t* value) {
    *value = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = Peek();
      uint32_t digit;
      if (c >= '0' && c <= '9') digit = static_cast<uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') digit = static_cast<uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') digit = static_cast<uint32_t>(c - 'A' + 10);
      else return false;
      ++offset_; *value = (*value << 4) | digit;
    }
    return true;
  }
  bool String() {
    if (!Take('"')) return false;
    while (offset_ < input_.size()) {
      const auto c = static_cast<uint8_t>(input_[offset_++]);
      if (c == '"') return true;
      if (c < 0x20) return false;
      if (c != '\\') continue;
      const char escape = Peek();
      if (escape == '"' || escape == '\\' || escape == '/' || escape == 'b' ||
          escape == 'f' || escape == 'n' || escape == 'r' || escape == 't') { ++offset_; continue; }
      if (!Take('u')) return false;
      uint32_t codepoint;
      if (!Hex(&codepoint)) return false;
      if (codepoint >= 0xdc00 && codepoint <= 0xdfff) return false;
      if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
        uint32_t low;
        if (!Take('\\') || !Take('u') || !Hex(&low) || low < 0xdc00 || low > 0xdfff) return false;
      }
    }
    return false;
  }
  bool Digit() const { return Peek() >= '0' && Peek() <= '9'; }
  bool Number() {
    Take('-');
    if (!Take('0')) {
      if (Peek() < '1' || Peek() > '9') return false;
      while (Digit()) ++offset_;
    }
    if (Take('.')) { if (!Digit()) return false; while (Digit()) ++offset_; }
    if (Take('e') || Take('E')) {
      if (!Take('+')) Take('-');
      if (!Digit()) return false;
      while (Digit()) ++offset_;
    }
    return true;
  }
  bool Value(unsigned depth) {
    if (depth > 128) return false;
    Space();
    if (Peek() == '"') return String();
    if (Take('{')) {
      Space(); if (Take('}')) return true;
      do {
        Space(); if (!String()) return false;
        Space(); if (!Take(':') || !Value(depth + 1)) return false;
        Space(); if (Take('}')) return true;
      } while (Take(','));
      return false;
    }
    if (Take('[')) {
      Space(); if (Take(']')) return true;
      do {
        if (!Value(depth + 1)) return false;
        Space(); if (Take(']')) return true;
      } while (Take(','));
      return false;
    }
    return Peek() == 't' ? Literal("true") : Peek() == 'f' ? Literal("false") :
           Peek() == 'n' ? Literal("null") : Number();
  }
  std::string_view input_;
  size_t offset_ = 0;
};
inline bool IsJsonObject(const std::vector<uint8_t>& data) {
  if (data.empty()) return false;
  return JsonValidator(std::string_view(reinterpret_cast<const char*>(data.data()), data.size())).Object();
}


using Scalar = std::variant<bool, int64_t, double, std::string>;
inline bool EncodeScalar(const Scalar& value, std::vector<uint8_t>* bytes) {
  bytes->assign({'H', 'W', 'P', 1});
  if (const auto* boolean = std::get_if<bool>(&value)) {
    bytes->push_back(1); bytes->push_back(*boolean ? 1 : 0);
  } else if (const auto* text = std::get_if<std::string>(&value)) {
    if (!IsUtf8(*text) || text->size() > kPreferenceLimit - 5) return false;
    bytes->push_back(2); bytes->insert(bytes->end(), text->begin(), text->end());
  } else {
    uint64_t bits = 0;
    if (const auto* integer = std::get_if<int64_t>(&value)) {
      std::memcpy(&bits, integer, sizeof(bits)); bytes->push_back(3);
    } else if (const auto* number = std::get_if<double>(&value)) {
      if (!std::isfinite(*number)) return false;
      std::memcpy(&bits, number, sizeof(bits)); bytes->push_back(4);
    } else return false;
    for (unsigned i = 0; i < 8; ++i) bytes->push_back(static_cast<uint8_t>(bits >> (i * 8)));
  }
  return true;
}
inline bool DecodeScalar(const std::vector<uint8_t>& bytes, Scalar* value) {
  if (bytes.size() < 5 || bytes.size() > kPreferenceLimit || bytes[0] != 'H' || bytes[1] != 'W' || bytes[2] != 'P' || bytes[3] != 1) return false;
  if (bytes[4] == 1 && bytes.size() == 6 && bytes[5] <= 1) { *value = bytes[5] != 0; return true; }
  if (bytes[4] == 2) {
    const std::string text(bytes.begin() + 5, bytes.end());
    if (!IsUtf8(text)) return false;
    *value = text; return true;
  }
  if (bytes.size() != 13) return false;
  uint64_t bits = 0;
  for (unsigned i = 0; i < 8; ++i) bits |= static_cast<uint64_t>(bytes[i + 5]) << (i * 8);
  if (bytes[4] == 3) { int64_t integer; std::memcpy(&integer, &bits, sizeof(bits)); *value = integer; return true; }
  if (bytes[4] == 4) {
    double number; std::memcpy(&number, &bits, sizeof(bits));
    if (!std::isfinite(number)) return false;
    *value = number; return true;
  }
  return false;
}

using SecretMap = std::map<std::string, std::string>;
// One bounded Credential Manager record per vault gives atomic all-or-nothing
// authorization updates, including expiry and the legacy onelap.refresh field.
inline bool EncodeSecrets(const SecretMap& values, std::vector<uint8_t>* bytes) {
  bytes->assign({'H', 'W', 'E', 1});
  if (values.size() > 8) return false;
  for (const auto& item : values) {
    if (!IsNonEmptyText(item.first) || !IsNonEmptyText(item.second) ||
        !IsUtf8(item.first) || !IsUtf8(item.second) || item.first.size() > 255) return false;
    bytes->push_back(static_cast<uint8_t>(item.first.size()));
    bytes->push_back(static_cast<uint8_t>(item.second.size() & 0xff));
    bytes->push_back(static_cast<uint8_t>(item.second.size() >> 8));
    bytes->insert(bytes->end(), item.first.begin(), item.first.end());
    bytes->insert(bytes->end(), item.second.begin(), item.second.end());
    if (bytes->size() > kCredentialLimit) return false;
  }
  return true;
}
inline bool DecodeSecrets(const std::vector<uint8_t>& bytes, SecretMap* values) {
  values->clear();
  if (bytes.size() < 4 || bytes.size() > kCredentialLimit || bytes[0] != 'H' ||
      bytes[1] != 'W' || bytes[2] != 'E' || bytes[3] != 1) return false;
  size_t offset = 4;
  while (offset < bytes.size()) {
    if (bytes.size() - offset < 3 || values->size() >= 8) return false;
    const size_t key_size = bytes[offset++];
    const size_t value_size = static_cast<size_t>(bytes[offset]) |
                              (static_cast<size_t>(bytes[offset + 1]) << 8);
    offset += 2;
    if (key_size > bytes.size() - offset || value_size > bytes.size() - offset - key_size) return false;
    const std::string key(bytes.begin() + offset, bytes.begin() + offset + key_size);
    offset += key_size;
    const std::string value(bytes.begin() + offset, bytes.begin() + offset + value_size);
    offset += value_size;
    if (!IsNonEmptyText(key) || !IsNonEmptyText(value) || !IsUtf8(key) || !IsUtf8(value) ||
        !values->emplace(key, value).second) return false;
  }
  return true;
}
}  // namespace native_channels
#endif  // RUNNER_NATIVE_CHANNEL_VALIDATION_H_
