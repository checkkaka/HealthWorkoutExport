#ifndef RUNNER_OAUTH_VALIDATION_H_
#define RUNNER_OAUTH_VALIDATION_H_

#include <algorithm>
#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>

// Portable validation shared by the Win32 flow and tests. It never performs I/O.
namespace strava_oauth {
constexpr size_t kMaximumRequestBytes = 16 * 1024;
constexpr uint32_t kTimeoutSeconds = 300;
using Parameters = std::map<std::string, std::string>;

inline bool IsDigit(char c) { return c >= '0' && c <= '9'; }
inline bool IsHex(char c) {
  return IsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
inline int HexValue(char c) {
  if (IsDigit(c)) return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return c - 'A' + 10;
}
inline std::string LowerAscii(std::string text) {
  for (char& c : text) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 'a' - 'A');
  return text;
}
inline std::string_view Trim(std::string_view text) {
  while (!text.empty() && (text.front() == ' ' || text.front() == '\t')) text.remove_prefix(1);
  while (!text.empty() && (text.back() == ' ' || text.back() == '\t')) text.remove_suffix(1);
  return text;
}
inline std::optional<std::string> DecodeQueryValue(std::string_view raw) {
  std::string value;
  if (raw.size() > kMaximumRequestBytes) return std::nullopt;
  for (size_t i = 0; i < raw.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(raw[i]);
    if (c == '%') {
      if (i + 2 >= raw.size() || !IsHex(raw[i + 1]) || !IsHex(raw[i + 2])) return std::nullopt;
      c = static_cast<unsigned char>((HexValue(raw[i + 1]) << 4) | HexValue(raw[i + 2]));
      i += 2;
    } else if (c == '+') c = ' ';
    if (c < 0x20 || c > 0x7e) return std::nullopt;
    value.push_back(static_cast<char>(c));
  }
  return value;
}
inline std::string EncodeQueryValue(std::string_view value) {
  constexpr char hex[] = "0123456789ABCDEF";
  std::string result;
  for (unsigned char c : value) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
        c == '-' || c == '_' || c == '.' || c == '~') result.push_back(static_cast<char>(c));
    else { result += '%'; result += hex[c >> 4]; result += hex[c & 15]; }
  }
  return result;
}
inline std::optional<Parameters> ParseQuery(std::string_view raw) {
  if (raw.empty() || raw.size() > kMaximumRequestBytes || raw.find('#') != std::string_view::npos) return std::nullopt;
  Parameters result;
  while (!raw.empty()) {
    const auto separator = raw.find('&');
    const auto pair = raw.substr(0, separator);
    const auto equals = pair.find('=');
    if (equals == std::string_view::npos) return std::nullopt;
    auto key = DecodeQueryValue(pair.substr(0, equals));
    auto value = DecodeQueryValue(pair.substr(equals + 1));
    if (!key || key->empty() || !value || !result.emplace(*key, *value).second) return std::nullopt;
    if (separator == std::string_view::npos) break;
    raw.remove_prefix(separator + 1);
    if (raw.empty()) return std::nullopt;
  }
  return result;
}
inline bool ConstantTimeEqual(std::string_view left, std::string_view right) {
  if (left.size() != right.size()) return false;
  unsigned char difference = 0;
  for (size_t i = 0; i < left.size(); ++i) difference |= static_cast<unsigned char>(left[i] ^ right[i]);
  return difference == 0;
}
inline std::set<std::string> Scopes(std::string_view raw) {
  std::set<std::string> scopes;
  size_t start = 0;
  for (size_t i = 0; i <= raw.size(); ++i) {
    if (i == raw.size() || raw[i] == ',' || raw[i] == ' ') {
      if (i > start) scopes.emplace(raw.substr(start, i - start));
      start = i + 1;
    }
  }
  return scopes;
}

// Strava explicitly allow-lists 127.0.0.1 loopback redirects. The original mobile
// contract is validated first, then only endpoint/redirect/state are adapted.
// https://developers.strava.com/docs/authentication/
inline std::optional<std::string> BuildAuthorizationUrl(
    std::string_view raw, std::string_view callback_scheme, std::string_view state, uint16_t port) {
  constexpr std::string_view prefix = "https://www.strava.com/oauth/mobile/authorize?";
  if (raw.size() > kMaximumRequestBytes || raw.substr(0, prefix.size()) != prefix ||
      callback_scheme != "healthworkoutexport" || port == 0 || state.size() != 64 ||
      !std::all_of(state.begin(), state.end(), IsHex)) return std::nullopt;
  auto query = ParseQuery(raw.substr(prefix.size()));
  if (!query) return std::nullopt;
  const std::set<std::string> allowed = {"client_id", "redirect_uri", "response_type", "approval_prompt", "scope"};
  for (const auto& entry : *query) if (allowed.count(entry.first) == 0) return std::nullopt;
  const auto& id = (*query)["client_id"];
  if (id.empty() || id.size() > 32 || !std::all_of(id.begin(), id.end(), IsDigit) ||
      (*query)["redirect_uri"] != "healthworkoutexport://localhost/callback" ||
      (*query)["response_type"] != "code") return std::nullopt;
  auto& approval = (*query)["approval_prompt"];
  if (approval.empty()) approval = "auto";
  if (approval != "auto" && approval != "force") return std::nullopt;
  const auto scopes = Scopes((*query)["scope"]);
  const std::set<std::string> supported = {"read", "read_all", "profile:read_all", "profile:write", "activity:read", "activity:read_all", "activity:write"};
  if (scopes.count("activity:read_all") == 0 || scopes.count("activity:write") == 0) return std::nullopt;
  for (const auto& scope : scopes) if (supported.count(scope) == 0) return std::nullopt;
  (*query)["redirect_uri"] = "http://127.0.0.1:" + std::to_string(port) + "/callback";
  (*query)["state"] = std::string(state);
  std::string url = "https://www.strava.com/oauth/authorize?";
  for (const auto& entry : *query) {
    if (url.back() != '?') url += '&';
    url += EncodeQueryValue(entry.first) + "=" + EncodeQueryValue(entry.second);
  }
  return url;
}

enum class CallbackKind { kIgnore, kAuthorized, kDenied, kRejected, kScopeDenied };
struct Callback {
  CallbackKind kind = CallbackKind::kIgnore;
  std::string authorization_code;
};
inline Callback ParseCallbackRequest(std::string_view request, uint16_t port, std::string_view state) {
  if (request.size() > kMaximumRequestBytes || port == 0 || state.size() != 64) return {};
  const auto headers_end = request.find("\r\n\r\n");
  const auto first_end = request.find("\r\n");
  if (headers_end == std::string_view::npos || first_end == std::string_view::npos) return {};
  const auto first = request.substr(0, first_end);
  if (first.substr(0, 4) != "GET ") return {};
  const auto version = first.find(' ', 4);
  if (version == std::string_view::npos || (first.substr(version) != " HTTP/1.1" && first.substr(version) != " HTTP/1.0")) return {};
  const auto target = first.substr(4, version - 4);
  constexpr std::string_view path = "/callback?";
  if (target.substr(0, path.size()) != path) return {};
  unsigned host_count = 0;
  size_t cursor = first_end + 2;
  while (cursor < headers_end) {
    const auto end = request.find("\r\n", cursor);
    if (end == std::string_view::npos || end > headers_end) return {};
    const auto line = request.substr(cursor, end - cursor);
    const auto colon = line.find(':');
    if (line.empty() || line.front() == ' ' || line.front() == '\t' || colon == std::string_view::npos) return {};
    if (LowerAscii(std::string(line.substr(0, colon))) == "host") {
      ++host_count;
      if (Trim(line.substr(colon + 1)) != "127.0.0.1:" + std::to_string(port)) return {};
    }
    cursor = end + 2;
  }
  if (host_count != 1) return {};
  auto query = ParseQuery(target.substr(path.size()));
  if (!query || query->count("state") != 1 || !ConstantTimeEqual((*query)["state"], state)) return {};
  if (query->count("error") != 0) {
    return {(*query)["error"] == "access_denied" ? CallbackKind::kDenied : CallbackKind::kRejected, {}};
  }
  const auto code = query->find("code");
  if (code == query->end() || code->second.empty() || code->second.size() > 8192 ||
      !std::all_of(code->second.begin(), code->second.end(), [](unsigned char c) { return c >= 0x21 && c <= 0x7e; })) return {};
  const auto scopes = Scopes((*query)["scope"]);
  if (scopes.count("activity:read_all") == 0 || scopes.count("activity:write") == 0) return {CallbackKind::kScopeDenied, {}};
  return {CallbackKind::kAuthorized, code->second};
}

}  // namespace strava_oauth
#endif  // RUNNER_OAUTH_VALIDATION_H_
