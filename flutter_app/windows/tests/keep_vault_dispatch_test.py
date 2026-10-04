#!/usr/bin/env python3
"""Exercise the production Keep dispatch against a synthetic credential backend.

This portable check compiles the unmodified functions extracted from the Win32
translation unit. The replacement backend models atomic Credential Manager
writes; no Windows installation, real credentials, or network is used. A native
Windows adapter build is still required separately.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class KeepVaultDispatchTest(unittest.TestCase):
    def test_production_keep_dispatch(self):
        source = (ROOT / "runner/native_channels.cpp").read_text()
        self.assertTrue('method == "keepStatus"' in source,
                        "The production third-party vault must dispatch Keep")
        checks = source[source.index("const Value* Argument("):source.index("std::wstring Wide(")]
        dispatch = source[source.index("bool Present("):source.index("bool EncodePreference(")]
        shim = r'''
#include "native_channel_validation.h"
#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <limits>
#include <locale>
#include <memory>
#include <sstream>
#include <utility>
struct Value : std::variant<std::monostate, bool, int32_t, double, std::string, std::map<Value, Value>> {
  using variant::variant;
  Value(const char* s) : variant(std::string(s)) {}
};
using Map = std::map<Value, Value>;
using Bytes = std::vector<uint8_t>;
using native_channels::SecretMap;
struct Call {
  std::string method;
  Value arguments_value;
  const std::string& method_name() const { return method; }
  const Value* arguments() const { return &arguments_value; }
};
struct Result {
  int replies = 0;
  std::string code;
  Value value;
  void Error(const std::string& c, const std::string&) { ++replies; code = c; }
  void Success(Value v = {}) { ++replies; code = "success"; value = std::move(v); }
  void NotImplemented() { ++replies; code = "not_implemented"; }
};
std::map<std::string, SecretMap> storage;
int writes = 0;
bool fail_write = false, fail_clear = false, corrupt_record = false;
int reads = 0;
bool ReadVault(const std::string& vault, SecretMap* state, Result* result) {
  ++reads;
  if (vault == "keep" && corrupt_record) { result->Error("credential_store_corrupt", "synthetic corruption"); return false; }
  *state = storage[vault]; return true;
}
bool WriteVault(const std::string& vault, const SecretMap& state, Result* result) {
  ++writes;
  if (fail_write) { result->Error("credential_store_error", "synthetic failure"); return false; }
  Bytes encoded;
  if (!native_channels::EncodeSecrets(state, &encoded)) {
    result->Error("invalid_arguments", "invalid credentials"); return false;
  }
  storage[vault] = state;
  return true;
}
void ClearVault(const std::string& vault, Result* result) {
  if (fail_clear) { result->Error("credential_store_error", "synthetic failure"); return; }
  storage.erase(vault); if (vault == "keep") corrupt_record = false; result->Success();
}
'''
        cases = r'''
void Check(bool value, const char* name) {
  if (!value) { std::cerr << "FAIL: " << name << "\n"; std::exit(1); }
}
Result Run(const std::string& method, Value args = {}, bool strava = false) {
  Result result; HandleVault(Call{method, std::move(args)}, &result, strava);
  Check(result.replies == 1, "Exactly one platform reply"); return result;
}
Map Credentials(const std::string& account = "synthetic-account", const std::string& token = "synthetic-token") {
  return {{Value("account"), Value(account)}, {Value("token"), Value(token)}};
}
int main() {
  auto result = Run("keepStatus");
  Check(result.code == "success" && std::get<Map>(result.value) == Map{{Value("hasAccount"), Value(false)}, {Value("hasToken"), Value(false)}}, "Empty status exposes only flags");
  Check(Run("keepLease").code == "keep_not_configured", "Missing authorization cannot be leased");
  Check(Run("keepStatus", {}, true).code == "not_implemented", "Keep is only on third-party channel");
  storage["onelap"] = {{"onelap.account", "another-provider"}};
  Check(Run("writeKeepAuthorization", Credentials()).code == "success", "Valid account and token accepted");
  Check(writes == 1 && storage["keep"] == SecretMap{{"keep.account", "synthetic-account"}, {"keep.token", "synthetic-token"}}, "One complete two-field record written");
  Check(std::get<Map>(Run("keepStatus").value) == Map{{Value("hasAccount"), Value(true)}, {Value("hasToken"), Value(true)}}, "Authorized status never exposes account or token");
  Check(std::get<Map>(Run("keepLease").value) == Credentials(), "Lease contains only account and token");
  const auto saved = storage["keep"];
  for (const auto* extra : {"password", "refreshToken", "sessionId", "secret", "other"}) {
    auto args = Credentials(); args.emplace(Value(extra), Value("do-not-save"));
    Check(Run("writeKeepAuthorization", args).code == "invalid_arguments", "Extra credential key rejected");
    Check(storage["keep"] == saved && writes == 1, "Invalid input does not reach credential writer");
  }
  for (Value args : {Value{}, Value("not-a-map"), Value(Map{}), Value(Map{{Value("account"), Value("a")}}),
      Value(Map{{Value("account"), Value(42)}, {Value("token"), Value("t")}}),
      Value(Map{{Value("account"), Value("a")}, {Value("token"), Value{}}}),
      Value(Credentials("", "t")), Value(Credentials("a", " \n\t")),
      Value(Credentials(std::string("a\0b", 3), "t")), Value(Credentials("a", std::string("\xff", 1))),
      Value(Credentials("a", std::string(native_channels::kCredentialLimit + 1, 'x')))}) {
    Check(Run("writeKeepAuthorization", args).code == "invalid_arguments", "Malformed Keep arguments rejected");
    Check(storage["keep"] == saved, "Invalid arguments preserve prior record");
  }
  fail_write = true;
  Check(Run("writeKeepAuthorization", Credentials("new", "new-token")).code == "credential_store_error", "Write failure is surfaced");
  Check(storage["keep"] == saved, "Failed atomic write leaves previous complete authorization");
  fail_write = false;
  Check(Run("writeKeepAuthorization", Credentials("new", "new-token")).code == "success", "Successful reauthorization replaces pair");
  Check(std::get<Map>(Run("keepLease").value) == Credentials("new", "new-token"), "New account never leases old token");
  fail_clear = true;
  Check(Run("clearKeepAuthorization").code == "credential_store_error", "Clear failure is surfaced");
  fail_clear = false;
  Check(Run("clearKeepAuthorization").code == "success", "Clear succeeds");
  Check(Run("keepLease").code == "keep_not_configured", "Cleared credentials unavailable");
  Check(Run("clearKeepAuthorization").code == "success", "Clear is idempotent");
  for (const auto& partial : {SecretMap{{"keep.account", "only-account"}}, SecretMap{{"keep.token", "only-token"}}}) {
    storage["keep"] = partial;
    Check(Run("keepLease").code == "keep_not_configured", "Partial record fails closed");
  }
  corrupt_record = true;
  Check(Run("keepStatus").code == "credential_store_corrupt", "Corrupt status fails closed");
  const auto before_write = writes;
  Check(Run("writeKeepAuthorization", Credentials()).code == "credential_store_corrupt", "Login cannot silently overwrite corruption");
  Check(writes == before_write, "Corrupt storage never reaches writer");
  const auto before_reset_reads = reads;
  fail_clear = true;
  Check(Run("resetKeepAuthorization").code == "credential_store_error", "Reset deletion failure is surfaced");
  Check(corrupt_record, "Failed reset cannot claim corruption is cleared");
  fail_clear = false;
  Check(Run("resetKeepAuthorization").code == "success", "Explicit reset recovers corrupt record");
  Check(Run("resetKeepAuthorization").code == "success", "Reset is idempotent");
  Check(reads == before_reset_reads, "Reset never reads or decodes old record");
  Check(Run("resetKeepAuthorization", {}, true).code == "not_implemented", "Reset cannot reach Strava channel");
  Check(Run("resetOnelapAuthorization").code == "not_implemented", "Reset is Keep-specific");
  Check(Run("writeKeepAuthorization", Credentials()).code == "success", "Login works after confirmed reset");
  Check(storage["onelap"] == SecretMap{{"onelap.account", "another-provider"}}, "Other vaults are untouched");
  std::cout << "Keep production dispatch tests passed (synthetic backend)\n";
}
'''
        with tempfile.TemporaryDirectory(prefix="hwe-keep-windows-") as directory:
            unit = Path(directory) / "dispatch.cpp"
            unit.write_text(shim + checks + dispatch + cases)
            binary = Path(directory) / ("keep_dispatch.exe" if os.name == "nt" else "keep_dispatch")
            compiler = os.environ.get("CXX", "g++")
            if Path(compiler).stem.lower() in ("cl", "clang-cl"):
                command = [compiler, "/nologo", "/std:c++17", "/EHsc", "/W4", "/WX", "/utf-8",
                           f'/I{ROOT / "runner"}', str(unit), f"/Fe{binary}"]
            else:
                command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pedantic",
                           "-I", str(ROOT / "runner"), str(unit), "-o", str(binary)]
            subprocess.run(command, cwd=directory, check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
