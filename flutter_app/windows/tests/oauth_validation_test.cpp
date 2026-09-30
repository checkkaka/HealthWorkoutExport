#include "../runner/oauth_validation.h"
#include <cstdlib>
#include <iostream>

namespace {
int checks = 0;
void Check(bool valid) { ++checks; if (!valid) { std::cerr << "OAuth check failed: " << checks << '\n'; std::exit(1); } }
const std::string state(64, 'a');
const std::string base = "https://www.strava.com/oauth/mobile/authorize?client_id=123&redirect_uri=healthworkoutexport%3A%2F%2Flocalhost%2Fcallback&response_type=code&approval_prompt=auto&scope=activity%3Aread_all%2Cactivity%3Awrite%2Cread";
std::string Request(const std::string& query, const std::string& host = "127.0.0.1:49152") {
  return "GET /callback?" + query + " HTTP/1.1\r\nHost: " + host + "\r\nConnection: close\r\n\r\n";
}
std::string GoodQuery() { return "state=" + state + "&code=one-time-code&scope=read%2Cactivity%3Aread_all%2Cactivity%3Awrite"; }
}
int main() {
  using namespace strava_oauth;
  const auto url = BuildAuthorizationUrl(base, "healthworkoutexport", state, 49152);
  Check(url.has_value());
  Check(url->find("https://www.strava.com/oauth/authorize?") == 0);
  Check(url->find("redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fcallback") != std::string::npos);
  Check(url->find("state=" + state) != std::string::npos);
  for (const auto& raw : {base + "&state=attacker", base + "&client_id=456", base + "&redirect_uri=evil", base + "#fragment", base + "&unknown=x", std::string("https://www.strava.com.evil/oauth/mobile/authorize?client_id=1")}) {
    Check(!BuildAuthorizationUrl(raw, "healthworkoutexport", state, 49152));
  }
  Check(!BuildAuthorizationUrl(base + "&%73tate=attacker", "healthworkoutexport", state, 49152));
  auto bad_redirect = base;
  bad_redirect.replace(bad_redirect.find("localhost"), std::string("localhost").size(), "evil.test");
  Check(!BuildAuthorizationUrl(bad_redirect, "healthworkoutexport", state, 49152));
  auto bad_id = base;
  bad_id.replace(bad_id.find("client_id=123"), std::string("client_id=123").size(), "client_id=123%0A");
  Check(!BuildAuthorizationUrl(bad_id, "healthworkoutexport", state, 49152));
  Check(!BuildAuthorizationUrl(base, "other", state, 49152));
  Check(!BuildAuthorizationUrl(base, "healthworkoutexport", "short", 49152));
  Check(!BuildAuthorizationUrl(base, "healthworkoutexport", std::string(64,'z'), 49152));
  Check(!BuildAuthorizationUrl(base, "healthworkoutexport", state, 0));
  auto callback = ParseCallbackRequest(Request(GoodQuery()), 49152, state);
  Check(callback.kind == CallbackKind::kAuthorized);
  Check(callback.authorization_code == "one-time-code");
  Check(ParseCallbackRequest(Request("state="+state+"&error=access_denied"),49152,state).kind == CallbackKind::kDenied);
  Check(ParseCallbackRequest(Request("state="+state+"&error=server_error"),49152,state).kind == CallbackKind::kRejected);
  Check(ParseCallbackRequest(Request("state="+state+"&code=x&scope=read"),49152,state).kind == CallbackKind::kScopeDenied);
  for (const auto& query : {GoodQuery()+"&state="+state, GoodQuery()+"&code=duplicate", GoodQuery()+"&scope=duplicate", std::string("code=x&scope=activity%3Awrite"), std::string("state=wrong&code=x"), std::string("state=")+state+"&code=%0D%0AHeader", std::string("state=")+state+"&code=x%ZZ", GoodQuery()+"#fragment"}) {
    Check(ParseCallbackRequest(Request(query),49152,state).kind == CallbackKind::kIgnore);
  }
  Check(ParseCallbackRequest(Request(GoodQuery()+"&%73tate="+state),49152,state).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest(Request("state="+state+"&code=&scope=activity%3Aread_all,activity%3Awrite"),49152,state).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest(Request("state="+state+"&code=with+space&scope=activity%3Aread_all,activity%3Awrite"),49152,state).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest(Request("state="+state+"&code=x&scope=activity%3Aread_all_evil,activity%3Awrite"),49152,state).kind == CallbackKind::kScopeDenied);
  Check(ParseCallbackRequest(Request(GoodQuery(),"evil.test:49152"),49152,state).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest(Request(GoodQuery(),"127.0.0.1:49153"),49152,state).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest(Request(GoodQuery(),"127.0.0.1:49152\r\nHost: 127.0.0.1:49152"),49152,state).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest(Request(GoodQuery()),49152,std::string(64,'b')).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest(std::string(kMaximumRequestBytes+1,'x'),49152,state).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest("GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1:49152\r\n\r\n",49152,state).kind == CallbackKind::kIgnore);
  Check(ParseCallbackRequest("POST /callback?"+GoodQuery()+" HTTP/1.1\r\nHost: 127.0.0.1:49152\r\n\r\n",49152,state).kind == CallbackKind::kIgnore);
  Check(!DecodeQueryValue("%00")); Check(!DecodeQueryValue("%1f")); Check(!DecodeQueryValue("%7f")); Check(!DecodeQueryValue("%"));
  Check(DecodeQueryValue("a%2Bb+c") == std::optional<std::string>("a+b c"));
  Check(ConstantTimeEqual(state,state)); Check(!ConstantTimeEqual(state,"a"));
  std::cout << "Windows OAuth portable validation: " << checks << " checks passed\n";
}
