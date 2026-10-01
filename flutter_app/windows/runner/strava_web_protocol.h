#ifndef RUNNER_STRAVA_WEB_PROTOCOL_H_
#define RUNNER_STRAVA_WEB_PROTOCOL_H_

#include "strava_web_security.h"

#include <map>
#include <utility>

namespace strava_web {
using Bytes = std::vector<uint8_t>;
using Headers = std::map<std::string, std::string>;
struct Response { bool received = false; int status = 0; std::string body, location; };
struct Request {
  std::string path, method, cookie;
  Headers headers;
  std::string prefix, suffix;
  const Bytes* fit = nullptr;
};
class Transport {
 public:
  virtual ~Transport() = default;
  virtual Response Execute(const Request& request) = 0;
};
enum class Operation { Probe, Upload, Delete, List, Speed };
struct Job {
  Operation operation = Operation::Probe;
  std::map<std::string, std::string> cookies;
  std::string remote_id, filename, listing_path, boundary;
  Bytes fit;
};
struct Outcome {
  bool success = false, ready = false, missing = false, duplicate = false, may_have_mutated = false;
  std::string remote_id, json, page_html, streams_json;
};
inline constexpr char kProbePath[] = "/athlete/training_activities?start_date=01%2F01%2F2010&end_date=12%2F31%2F2035&page=1&new_activity_only=false";
inline Response Execute(Transport* transport, const Job& job, const std::string& path,
    const std::string& method = "GET", Headers headers = {}, const std::string& prefix = "",
    const Bytes* fit = nullptr, const std::string& suffix = "") {
  if (!IsFixedRequestPath(path) || (method != "GET" && method != "POST")) return {};
  const auto cookie = job.cookies.find(path.substr(0, path.find('?')));
  if (cookie == job.cookies.end() || cookie->second.empty() || cookie->second.size() > kMaxCookieBytes) return {};
  if (!headers.count("Accept")) headers["Accept"] = "text/html";
  if (!headers.count("Referer")) headers["Referer"] = std::string(kOrigin) + "/athlete/training";
  headers["X-Requested-With"] = "XMLHttpRequest";
  if (job.operation == Operation::Delete && method == "POST") headers.erase("X-Requested-With");
  auto response = transport->Execute({path, method, cookie->second, std::move(headers), prefix, suffix, fit});
  if (response.body.size() > kMaxResponseBytes || !native_channels::IsUtf8(response.body)) return {};
  return response;
}
inline Outcome Perform(Transport* transport, const Job& job) {
  Outcome outcome;
  if (job.operation == Operation::Probe || job.operation == Operation::List) {
    const auto response = Execute(transport, job, job.operation == Operation::Probe ? kProbePath : job.listing_path,
                                  "GET", {{"Accept", "application/json"}});
    outcome.ready = response.received && response.status == 200 && HasActivityArray(response.body);
    outcome.success = job.operation == Operation::Probe || outcome.ready;
    if (outcome.ready) outcome.json = response.body;
    return outcome;
  }
  if (job.operation == Operation::Speed) {
    if (!native_channels::IsActivityId(job.remote_id)) return outcome;
    const auto path = "/activities/" + job.remote_id;
    const auto page = Execute(transport, job, path);
    if (page.received && page.status == 404) { outcome.success = true; outcome.missing = true; return outcome; }
    if (!page.received || page.status != 200 || Lower(page.body).find("log in") != std::string::npos) return outcome;
    outcome.page_html = page.body;
    const auto streams = Execute(transport, job, path + "/streams?stream_types%5B%5D=velocity_smooth", "GET", {{"Accept", "application/json"}});
    if (streams.received && streams.status == 200 && native_channels::JsonValidator(streams.body).Collection()) outcome.streams_json = streams.body;
    outcome.success = true;
    return outcome;
  }
  if (job.operation == Operation::Delete && !native_channels::IsActivityId(job.remote_id)) return outcome;
  if (job.operation == Operation::Upload && (job.fit.empty() || job.fit.size() > native_channels::kFitLimit ||
      !IsSafeFilename(job.filename) || job.boundary.empty() || job.boundary.size() > 128 || !IsCookieName(job.boundary))) return outcome;
  const std::vector<std::string> paths = job.operation == Operation::Delete
    ? std::vector<std::string>{"/activities/" + job.remote_id, "/about", "/upload/select"}
    : std::vector<std::string>{"/about", "/upload/select"};
  Csrf csrf;
  for (const auto& path : paths) {
    const auto response = Execute(transport, job, path);
    if (!response.received) continue;
    if (job.operation == Operation::Delete && path == paths.front() && response.status == 404) { outcome.success = true; return outcome; }
    if (response.status == 401 || response.status == 403 || (response.status >= 300 && response.status < 400)) return outcome;
    if (response.status == 200) csrf = ExtractCsrf(response.body);
    if (!csrf.token.empty()) break;
  }
  if (csrf.token.empty()) return outcome;
  if (job.operation == Operation::Delete) {
    const auto path = "/activities/" + job.remote_id;
    const std::string form = "_method=delete&" + PercentEncode(csrf.parameter) + "=" + PercentEncode(csrf.token);
    outcome.may_have_mutated = true;
    // Exactly one mutating request. A network error never automatically replays it.
    const auto response = Execute(transport, job, path, "POST", {
      {"Content-Type", "application/x-www-form-urlencoded"}, {"Origin", kOrigin},
      {"Referer", std::string(kOrigin) + path}, {"Accept", "text/html,application/xhtml+xml"}}, form);
    outcome.success = response.received && DeletionSucceeded(response.status, response.location, response.body);
    return outcome;
  }
  const auto delimiter = "--" + job.boundary + "\r\n";
  const auto prefix = delimiter + "Content-Disposition: form-data; name=\"_method\"\r\n\r\npost\r\n" +
    delimiter + "Content-Disposition: form-data; name=\"authenticity_token\"\r\n\r\n" + csrf.token + "\r\n" +
    delimiter + "Content-Disposition: form-data; name=\"files[]\"; filename=\"" + job.filename +
    "\"\r\nContent-Type: application/octet-stream\r\n\r\n";
  outcome.may_have_mutated = true;
  const auto response = Execute(transport, job, "/upload/files", "POST", {
    {"Origin", kOrigin}, {"Referer", std::string(kOrigin) + "/upload/select"},
    {"X-CSRF-Token", csrf.token}, {"Content-Type", "multipart/form-data; boundary=" + job.boundary}},
    prefix, &job.fit, "\r\n--" + job.boundary + "--\r\n");
  if (!response.received || !((response.status >= 200 && response.status < 300) || response.status == 400 || response.status == 409 || response.status == 422)) return outcome;
  outcome.duplicate = IsDuplicate(response.body);
  outcome.remote_id = DuplicateId(response.body);
  outcome.success = outcome.duplicate || (response.status >= 200 && response.status < 300 && Lower(response.body).find("log in") == std::string::npos);
  return outcome;
}
}  // namespace strava_web
#endif  // RUNNER_STRAVA_WEB_PROTOCOL_H_
