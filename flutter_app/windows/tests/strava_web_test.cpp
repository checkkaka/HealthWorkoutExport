#include "../runner/strava_web_protocol.h"

#include <cstdlib>
#include <iostream>
#include <utility>

namespace {
size_t assertions = 0;
void Check(bool condition, const char* description) {
  ++assertions;
  if (!condition) { std::cerr << "FAIL: " << description << '\n'; std::exit(1); }
}
class FakeTransport final : public strava_web::Transport {
 public:
  std::vector<strava_web::Response> responses;
  std::vector<strava_web::Request> requests;
  strava_web::Response Execute(const strava_web::Request& request) override {
    requests.push_back(request);
    if (requests.size() > responses.size()) return {};
    return responses[requests.size() - 1];
  }
};
strava_web::Job MakeJob(strava_web::Operation operation) {
  strava_web::Job job;
  job.operation = operation; job.remote_id = "123"; job.filename = "training.fit";
  job.boundary = "Boundary-test-only"; job.fit = {0x0e, 0x10, 0x01};
  for (const auto* path : {"/about", "/upload/select", "/upload/files", "/athlete/training_activities", "/activities/123", "/activities/123/streams"}) job.cookies[path] = "session=synthetic";
  job.listing_path = strava_web::ActivityPagePath(1, 0, 86400000);
  return job;
}
constexpr char csrf[] = "<meta name='csrf-param' content='authenticity_token'><meta content='token+/=' name='csrf-token'>";
}
int main() {
  using namespace strava_web;
  for (const auto* url : {"https://www.strava.com/login", "HTTPS://www.strava.com:443/dashboard", "https://accounts.google.com/o/oauth2/auth", "https://appleid.apple.com/auth/authorize"}) Check(IsAllowedLoginUrl(url), "trusted HTTPS login origin accepted");
  for (const auto* url : {"http://www.strava.com/login", "https://www.strava.com.evil.test/login", "https://user@www.strava.com/login", "https://www.strava.com:80/login", "https://www.strava.com\\@evil.test", "file:///tmp/test", "https://evil.test/", "https://%77ww.strava.com/login", "https://www.strava.com\r\n/login"}) Check(!IsAllowedLoginUrl(url), "unsafe login origin rejected");
  for (const auto* path : {"/about", "/upload/files", "/athlete/training_activities?page=1", "/activities/123", "/activities/123/streams?stream_types%5B%5D=velocity_smooth"}) Check(IsFixedRequestPath(path), "fixed endpoint allowed");
  for (const auto* path : {"/activities/123/../settings", "/activities/-1", "//evil.test", "https://evil.test", "/athlete/profile", "/activities/123#bad", "/upload/files\r\nInjected: yes"}) Check(!IsFixedRequestPath(path), "non-allowlisted endpoint rejected");
  Check(IsSafeFilename("training_2026-01.fit") && IsSafeFilename("训练.fit"), "exporter filenames accepted");
  for (const auto* name : {"../x.fit", "x\r\n.fit", "a\".fit", "a/b.fit", "x.fit.exe", "a\\b.fit", "a fit.fit", ""}) Check(!IsSafeFilename(name), "multipart filename injection rejected");
  Check(!IsSafeFilename(std::string(125, 'a') + ".fit"), "filename limit enforced");
  Check(PercentEncode("+/=&") == "%2B%2F%3D%26", "CSRF form percent-encoding exact");
  Check(ExtractCsrf(csrf).token == "token+/=" && ExtractCsrf(csrf).parameter == "authenticity_token", "CSRF attributes may be reordered");
  Check(ExtractCsrf("<INPUT VALUE=\"token\" NAME=\"authenticity_token\">").token == "token", "hidden input CSRF supported");
  Check(ExtractCsrf("<meta name='csrf-token' content='bad\r\ntoken'>").token.empty(), "CSRF header injection rejected");
  Check(ExtractCsrf("<meta name='csrf-token' content='token'><meta name='csrf-param' content='_method'>").token.empty(), "CSRF method parameter collision rejected");
  Check(ExtractCsrf("<meta name='csrf-token' content='token'><meta name='csrf-param' content='x\" y'>").token.empty(), "CSRF parameter injection rejected");
  Check(ExtractCsrf(std::string(kMaxResponseBytes + 1, 'x')).token.empty(), "CSRF input bounded");
  std::vector<Cookie> cookies = {
    {"session", "root", ".strava.com", "/", 0, true},
    {"session", "specific", "www.strava.com", "/upload", 0, true},
    {"expired", "ignored", ".strava.com", "/", 10, false},
    {"foreign", "ignored", ".strava.com.evil.test", "/", 0, true},
    {"bad", "x\r\nInjected:y", ".strava.com", "/", 0, true}};
  Check(CookieHeader(cookies, "/upload/files", 100) == "session=specific", "cookie specificity and safety enforced");
  Check(CookieHeader(cookies, "/uploads", 100) == "session=root", "cookie path boundary enforced");
  Check(CookieHeader({{"x", std::string(kMaxCookieBytes, 'a'), ".strava.com", "/", 0, true}}, "/", 100).empty(), "cookie header size bounded");
  for (const auto* json : {"{\"models\":[]}", "{\"activities\":[{\"id\":1}]}"}) Check(HasActivityArray(json), "authenticated activity response accepted");
  for (const auto* json : {"{\"models\":null}", "{\"nested\":{\"models\":[]}}", "{\"x\":\"models\"}", "{\"models\":[]},junk", "[]", "<html>log in</html>"}) Check(!HasActivityArray(json), "unauthenticated or malformed probe rejected");
  Check(DuplicateId("Duplicate of activity 1234") == "1234", "duplicate plain ID parsed");
  Check(DuplicateId("duplicate of <a href='/activities/42'>activity</a>") == "42", "duplicate HTML ID parsed");
  Check(IsDuplicate("duplicate of <a>unknown</a>") && !IsDuplicate("not available"), "duplicate without ID recognized");
  Check(DuplicateId("duplicate of activity " + std::string(33, '1')).empty(), "oversized duplicate ID rejected");
  Check(DeletionSucceeded(404, "", "") && DeletionSucceeded(204, "", ""), "confirmed deletion statuses accepted");
  Check(DeletionSucceeded(302, "/athlete/training", "") && DeletionSucceeded(303, "https://www.strava.com/dashboard", ""), "safe delete landing redirect recognized without following");
  for (const auto* location : {"//evil.test/dashboard", "http://www.strava.com/dashboard", "https://evil.test/dashboard", "/login", "https://www.strava.com@evil.test/dashboard"}) Check(!DeletionSucceeded(302, location, ""), "untrusted delete redirect rejected");
  Check(!DeletionSucceeded(200, "", "Please log in") && !DeletionSucceeded(401, "", ""), "expired deletion session rejected");
  Check(DateFilter(-1) == "12%2F31%2F1969" && DateFilter(0) == "01%2F01%2F1970", "pre-epoch date math uses floor");
  Check(DateFilter(-2208988800000LL) == "01%2F01%2F1900", "1900 list boundary supported on Windows CRT");
  Check(DateFilter(1709164800000LL) == "02%2F29%2F2024", "leap-day date filter supported");
  Check(ActivityPagePath(1, 0, 86400000).find("start_date=12%2F31%2F1969&end_date=01%2F03%2F1970") != std::string::npos, "page filter widens date-only boundaries");
  Check(ActivityPagePath(0, 0, 100).empty() && ActivityPagePath(201, 0, 100).empty() && ActivityPagePath(1, 100, 0).empty(), "page bounds rejected");

  FakeTransport probe;
  probe.responses = {{true, 200, "{\"models\":[]}", ""}};
  Check(Perform(&probe, MakeJob(Operation::Probe)).ready, "probe performs authenticated native request");
  Check(probe.requests.size() == 1 && probe.requests[0].method == "GET", "probe never mutates");
  FakeTransport upload;
  upload.responses = {{true, 200, csrf, ""}, {true, 200, "{}", ""}};
  const auto upload_result = Perform(&upload, MakeJob(Operation::Upload));
  Check(upload_result.success && !upload_result.duplicate, "upload success acknowledged");
  Check(upload.requests.size() == 2 && upload.requests.back().path == "/upload/files" && upload.requests.back().method == "POST", "upload only posts to exact fixed endpoint");
  Check(upload.requests.back().prefix.find("name=\"files[]\"") != std::string::npos && upload.requests.back().headers.at("X-CSRF-Token") == "token+/=", "FIT multipart and CSRF contract encoded");
  FakeTransport duplicate;
  duplicate.responses = {{true, 200, csrf, ""}, {true, 409, "Duplicate of activity 42", ""}};
  const auto duplicated = Perform(&duplicate, MakeJob(Operation::Upload));
  Check(duplicated.success && duplicated.duplicate && duplicated.remote_id == "42", "duplicate upload outcome preserved");
  FakeTransport unavailable;
  unavailable.responses = {{true, 200, "No token here", ""}, {true, 200, "No token here", ""}};
  Check(!Perform(&unavailable, MakeJob(Operation::Upload)).success && unavailable.requests.size() == 2, "no upload without CSRF");
  FakeTransport failed_upload;
  failed_upload.responses = {{true, 200, csrf, ""}, {false, 0, "", ""}};
  const auto failed = Perform(&failed_upload, MakeJob(Operation::Upload));
  Check(!failed.success && failed.may_have_mutated && failed_upload.requests.size() == 2, "uncertain upload is not replayed");
  FakeTransport deletion;
  deletion.responses = {{true, 200, csrf, ""}, {true, 302, "", "/athlete/training"}};
  Check(Perform(&deletion, MakeJob(Operation::Delete)).success && deletion.requests.size() == 2, "deletion with confirmed redirect succeeds without following");
  Check(deletion.requests.back().prefix == "_method=delete&authenticity_token=token%2B%2F%3D", "delete form safely percent encoded");
  Check(!deletion.requests.back().headers.count("X-Requested-With"), "delete preserves ordinary Rails form semantics");
  FakeTransport uncertain_delete;
  uncertain_delete.responses = {{true, 200, csrf, ""}, {false, 0, "", ""}};
  const auto deleted = Perform(&uncertain_delete, MakeJob(Operation::Delete));
  Check(!deleted.success && deleted.may_have_mutated && uncertain_delete.requests.size() == 2, "uncertain deletion never replayed");
  FakeTransport missing_delete;
  missing_delete.responses = {{true, 404, "", ""}};
  Check(Perform(&missing_delete, MakeJob(Operation::Delete)).success && missing_delete.requests.size() == 1, "already absent activity does not trigger POST");
  FakeTransport list;
  list.responses = {{true, 200, "{\"activities\":[{\"id\":123}]}", ""}};
  Check(Perform(&list, MakeJob(Operation::List)).json == list.responses.front().body, "bounded listing JSON preserved for Rust");
  FakeTransport speed;
  speed.responses = {{true, 200, "<html>activity 123</html>", ""}, {true, 200, "{\"velocity_smooth\":[1,2]}", ""}};
  const auto speed_data = Perform(&speed, MakeJob(Operation::Speed));
  Check(speed_data.success && !speed_data.page_html.empty() && !speed_data.streams_json.empty(), "speed HTML and optional velocity stream returned");
  FakeTransport optional_stream;
  optional_stream.responses = {{true, 200, "<html>activity 123</html>", ""}, {true, 403, "", ""}};
  const auto optional_data = Perform(&optional_stream, MakeJob(Operation::Speed));
  Check(optional_data.success && !optional_data.page_html.empty() && optional_data.streams_json.empty(), "optional stream failure keeps page metadata");
  FakeTransport array_stream;
  array_stream.responses = {{true, 200, "<html>activity 123</html>", ""}, {true, 200, "[{\"type\":\"velocity_smooth\",\"data\":[1,2]}]", ""}};
  Check(!Perform(&array_stream, MakeJob(Operation::Speed)).streams_json.empty(), "array-shaped speed streams preserved for Rust");
  FakeTransport missing_speed;
  missing_speed.responses = {{true, 404, "", ""}};
  Check(Perform(&missing_speed, MakeJob(Operation::Speed)).missing, "missing speed activity returns null semantic");
  FakeTransport no_cookies;
  auto empty_job = MakeJob(Operation::Upload); empty_job.cookies.clear();
  Check(!Perform(&no_cookies, empty_job).success && no_cookies.requests.empty(), "no credentialless mutation");
  std::cout << assertions << " Windows Strava security/protocol assertions passed\n";
}
