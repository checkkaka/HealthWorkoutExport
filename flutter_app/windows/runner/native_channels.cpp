#include "native_channels.h"

#include <aclapi.h>
#include <sddl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincred.h>
#include <wrl/client.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>
#include <cstring>
#include <functional>
#include <string>
#include <utility>

#include "native_channel_validation.h"
#include "strava_web_plugin.h"
#include "strava_oauth.h"
#include "windows_timezone.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Call = flutter::MethodCall<Value>;
using Result = flutter::MethodResult<Value>;
using Bytes = std::vector<uint8_t>;
using native_channels::SecretMap;
using Microsoft::WRL::ComPtr;

class Handle {
 public:
  explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value_(value) {}
  ~Handle() { Reset(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value_(other.value_) { other.value_ = INVALID_HANDLE_VALUE; }
  HANDLE get() const { return value_; }
  bool valid() const { return value_ != nullptr && value_ != INVALID_HANDLE_VALUE; }
  void Reset() { if (valid()) CloseHandle(value_); value_ = INVALID_HANDLE_VALUE; }
 private:
  HANDLE value_;
};

struct Failure {
  std::string code = "sync_file_io";
  std::string message = "Local application storage operation failed";
  bool Set(const char* new_code, const char* new_message) {
    code = new_code; message = new_message; return false;
  }
  bool Win32(DWORD error = GetLastError(), const char* operation = "Win32") {
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
      Set("sync_file_missing", "The sync file does not exist");
    else if (error == ERROR_ACCESS_DENIED || error == ERROR_SHARING_VIOLATION)
      Set("sync_file_protected", "The private sync file is currently inaccessible");
    else
      Set("sync_file_io", "Local application storage operation failed");
    // Bounded operation labels and OS codes aid diagnosis without exposing paths,
    // file contents, user SIDs, or credentials. Protection remains fail-closed.
    message += " (" + std::string(operation) + ": " + std::to_string(error) + ")";
    return false;
  }
  void Reply(Result* result) const { result->Error(code, message); }
};

const Value* Argument(const Call& call, const char* key) {
  const auto* map = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (!map) return nullptr;
  const auto entry = map->find(Value(key));
  return entry == map->end() ? nullptr : &entry->second;
}
const std::string* Text(const Call& call, const char* key) {
  const Value* value = Argument(call, key);
  return value ? std::get_if<std::string>(value) : nullptr;
}
bool RequiredText(const Call& call, const char* key, std::string* output) {
  const auto* value = Text(call, key);
  if (!value || !native_channels::IsNonEmptyText(*value) || !native_channels::IsUtf8(*value)) return false;
  *output = *value; return true;
}
void Invalid(Result* result) { result->Error("invalid_arguments", "Invalid or oversized native channel arguments"); }

std::wstring Wide(const std::string& input) {
  if (input.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring output(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), output.data(), size);
  return output;
}
std::string Utf8(const std::wstring& input) {
  if (input.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string output(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), output.data(), size, nullptr, nullptr);
  return output;
}
std::wstring UniqueSuffix() {
  GUID guid;
  if (FAILED(CoCreateGuid(&guid))) return {};
  wchar_t buffer[40] = {};
  return StringFromGUID2(guid, buffer, 40) > 0 ? std::wstring(buffer) : std::wstring();
}

// Current user + SYSTEM only, with inheritance disabled at the app root.
// Directory handles omit FILE_SHARE_DELETE for the complete operation, preventing
// an ancestor from being swapped for a junction between validation and use.
class PrivateStorage {
 public:
  ~PrivateStorage() { if (descriptor_) LocalFree(descriptor_); }
  bool Prepare(const std::wstring& subdirectory, Failure* error) {
    HANDLE token_value = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token_value)) return error->Win32();
    Handle token(token_value);
    DWORD size = 0;
    GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
    if (size == 0) return error->Win32();
    Bytes token_info(size);
    if (!GetTokenInformation(token.get(), TokenUser, token_info.data(), size, &size)) return error->Win32();
    LPWSTR sid = nullptr;
    if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(token_info.data())->User.Sid, &sid)) return error->Win32();
    const std::wstring sddl = L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + std::wstring(sid) + L")";
    LocalFree(sid);
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor_, nullptr)) return error->Win32();
    BOOL present = FALSE, defaulted = FALSE;
    if (!GetSecurityDescriptorDacl(descriptor_, &present, &dacl_, &defaulted) || !present || !dacl_) return error->Win32();
    attributes_.nLength = static_cast<DWORD>(sizeof(attributes_));
    attributes_.lpSecurityDescriptor = descriptor_;
    attributes_.bInheritHandle = FALSE;
    PWSTR local = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local)))
      return error->Set("sync_file_io", "LocalAppData is unavailable");
    directory_ = local;
    CoTaskMemFree(local);
    if (!OpenDirectory(directory_, false, error)) return false;
    directory_ += L"\\HealthWorkoutExport";
    if (!OpenDirectory(directory_, true, error)) return false;
    if (!subdirectory.empty()) {
      directory_ += L"\\" + subdirectory;
      if (!OpenDirectory(directory_, true, error)) return false;
    }
    return true;
  }
  const std::wstring& directory() const { return directory_; }
  bool Read(const std::wstring& filename, size_t limit, Bytes* bytes, Failure* error) {
    Handle file(CreateFileW(Path(filename).c_str(), GENERIC_READ | WRITE_DAC, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!file.valid()) return error->Win32(GetLastError(), "OpenPrivateFile");
    if (!CheckFile(file.get(), error) || !Protect(file.get(), error)) return false;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(file.get(), &size)) return error->Win32();
    if (size.QuadPart < 0 || static_cast<uint64_t>(size.QuadPart) > limit)
      return error->Set("sync_file_too_large", "The file exceeds its size limit");
    bytes->resize(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    if (!bytes->empty() && (!ReadFile(file.get(), bytes->data(), static_cast<DWORD>(bytes->size()), &read, nullptr) || read != bytes->size()))
      return error->Win32();
    return true;
  }
  bool Write(const std::wstring& filename, const Bytes& bytes, Failure* error) {
    const auto suffix = UniqueSuffix();
    if (suffix.empty()) return error->Win32();
    const auto temporary = Path(filename + L".tmp-" + suffix);
    Handle file(CreateFileW(temporary.c_str(), GENERIC_WRITE | WRITE_DAC, 0, &attributes_, CREATE_NEW,
                            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!file.valid()) return error->Win32(GetLastError(), "OpenPrivateFile");
    if (!CheckFile(file.get(), error) || !Protect(file.get(), error)) {
      file.Reset();
      DeleteFileW(temporary.c_str());
      return false;  // Keep the failing validation operation and its exact code.
    }
    DWORD written = 0;
    const bool saved = WriteFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) &&
      written == bytes.size() && FlushFileBuffers(file.get());
    const DWORD write_error = saved ? ERROR_SUCCESS : GetLastError();
    file.Reset();
    if (!saved) { DeleteFileW(temporary.c_str()); return error->Win32(write_error, "WritePrivateFile"); }
    if (!MoveFileExW(temporary.c_str(), Path(filename).c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
      const DWORD move_error = GetLastError();
      DeleteFileW(temporary.c_str()); return error->Win32(move_error, "AtomicPrivateReplace");
    }
    return true;
  }
  bool Delete(const std::wstring& filename, Failure* error) {
    Handle file(CreateFileW(Path(filename).c_str(), DELETE | FILE_READ_ATTRIBUTES, 0, nullptr,
                            OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!file.valid()) {
      const DWORD code = GetLastError();
      return code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND || error->Win32(code);
    }
    if (!CheckFile(file.get(), error)) return false;
    FILE_DISPOSITION_INFO disposition = {TRUE};
    return SetFileInformationByHandle(file.get(), FileDispositionInfo, &disposition, sizeof(disposition)) || error->Win32();
  }
  bool Quarantine(const std::wstring& filename, Failure* error) {
    const auto suffix = UniqueSuffix();
    if (suffix.empty()) return error->Win32();
    return MoveFileExW(Path(filename).c_str(), Path(filename + L".corrupt-" + suffix).c_str(), MOVEFILE_WRITE_THROUGH) || error->Win32();
  }
 private:
  std::wstring Path(const std::wstring& filename) const { return directory_ + L"\\" + filename; }
  bool Protect(HANDLE object, Failure* error) {
    const DWORD status = SetSecurityInfo(object, SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, dacl_, nullptr);
    return status == ERROR_SUCCESS || error->Win32(status, "ProtectPrivateAcl");
  }
  bool OpenDirectory(const std::wstring& path, bool create, Failure* error) {
    if (create && !CreateDirectoryW(path.c_str(), &attributes_) && GetLastError() != ERROR_ALREADY_EXISTS) return error->Win32(GetLastError(), "CreatePrivateDirectory");
    Handle directory(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES | (create ? WRITE_DAC : 0),
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!directory.valid()) return error->Win32(GetLastError(), "OpenPrivateDirectory");
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(directory.get(), &info)) return error->Win32(GetLastError(), "InspectPrivateDirectory");
    if (!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
      return error->Set("sync_file_protected", "Reparse points are not allowed in private application storage");
    if (create && !Protect(directory.get(), error)) return false;
    directories_.push_back(std::move(directory)); return true;
  }
  static bool CheckFile(HANDLE file, Failure* error) {
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(file, &info)) return error->Win32(GetLastError(), "InspectPrivateFile");
    if ((info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) || info.nNumberOfLinks != 1)
      return error->Set("sync_file_protected", "Linked files are not allowed in private application storage");
    return true;
  }
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
  PACL dacl_ = nullptr;
  SECURITY_ATTRIBUTES attributes_ = {};
  std::wstring directory_;
  std::vector<Handle> directories_;
};

std::wstring VaultTarget(const std::string& vault) {
  return L"com.checkkaka.HealthWorkoutExport/" + Wide(vault) + L".vault.v1";
}
bool ReadVault(const std::string& vault, SecretMap* values, Result* result) {
  PCREDENTIALW credential = nullptr;
  if (!CredReadW(VaultTarget(vault).c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    if (GetLastError() == ERROR_NOT_FOUND) { values->clear(); return true; }
    result->Error("credential_store_error", "Windows Credential Manager could not read the authorization"); return false;
  }
  bool valid = credential->CredentialBlobSize <= native_channels::kCredentialLimit;
  Bytes bytes;
  if (valid && credential->CredentialBlobSize > 0)
    bytes.assign(credential->CredentialBlob, credential->CredentialBlob + credential->CredentialBlobSize);
  valid = valid && native_channels::DecodeSecrets(bytes, values);
  if (!bytes.empty()) SecureZeroMemory(bytes.data(), bytes.size());
  if (credential->CredentialBlobSize > 0) SecureZeroMemory(credential->CredentialBlob, credential->CredentialBlobSize);
  CredFree(credential);
  if (!valid) { result->Error("credential_store_corrupt", "Stored authorization is invalid; sign out and authorize again"); return false; }
  return true;
}
bool WriteVault(const std::string& vault, const SecretMap& values, Result* result) {
  Bytes bytes;
  if (!native_channels::EncodeSecrets(values, &bytes)) {
    if (!bytes.empty()) SecureZeroMemory(bytes.data(), bytes.size());
    result->Error("credential_too_large", "Authorization exceeds Windows Credential Manager limits"); return false;
  }
  std::wstring target = VaultTarget(vault);
  std::wstring user = L"HealthWorkoutExport";
  CREDENTIALW credential = {};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = target.data();
  credential.CredentialBlobSize = static_cast<DWORD>(bytes.size());
  credential.CredentialBlob = bytes.data();
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.UserName = user.data();
  const BOOL saved = CredWriteW(&credential, 0);
  SecureZeroMemory(bytes.data(), bytes.size());
  if (!saved) { result->Error("credential_store_error", "Windows Credential Manager could not save the authorization"); return false; }
  return true;
}
void ClearVault(const std::string& vault, Result* result) {
  if (!CredDeleteW(VaultTarget(vault).c_str(), CRED_TYPE_GENERIC, 0) && GetLastError() != ERROR_NOT_FOUND) {
    result->Error("credential_store_error", "Windows Credential Manager could not clear the authorization"); return;
  }
  result->Success();
}
bool Present(const SecretMap& state, const std::string& key) {
  const auto entry = state.find(key);
  return entry != state.end() && native_channels::IsNonEmptyText(entry->second);
}
std::string Stored(const SecretMap& state, const std::string& key) {
  const auto entry = state.find(key); return entry == state.end() ? std::string() : entry->second;
}
double Expiry(const SecretMap& state) {
  const auto value = Stored(state, "strava.expiresAt");
  std::istringstream input(value);
  input.imbue(std::locale::classic());
  double expiry = 0;
  char trailing;
  return (input >> expiry) && !(input >> trailing) && std::isfinite(expiry) && expiry > 0 ? expiry : 0;
}
void HandleVault(const Call& call, Result* result, bool strava) {
  const auto& method = call.method_name();
  std::string vault;
  if (strava && (method == "stravaStatus" || method == "stravaLease" || method == "writeStravaAuthorization" || method == "clearStravaAuthorization")) vault = "strava";
  else if (!strava && (method == "xingzheStatus" || method == "xingzheLease" || method == "writeXingzheAuthorization" || method == "clearXingzheAuthorization")) vault = "xingzhe";
  else if (!strava && (method == "onelapStatus" || method == "onelapLease" || method == "writeOnelapAuthorization" || method == "clearOnelapAuthorization")) vault = "onelap";
  else { result->NotImplemented(); return; }
  if (method.compare(0, 5, "clear") == 0) { ClearVault(vault, result); return; }
  SecretMap state;
  if (!ReadVault(vault, &state, result)) return;
  if (method.compare(0, 5, "write") == 0) {
    SecretMap next;
    const std::vector<std::pair<const char*, const char*>> fields = strava
      ? std::vector<std::pair<const char*, const char*>>{{"clientId", "strava.clientId"}, {"clientSecret", "strava.clientSecret"}, {"accessToken", "strava.accessToken"}, {"refreshToken", "strava.refreshToken"}}
      : vault == "xingzhe" ? std::vector<std::pair<const char*, const char*>>{{"account", "xingzhe.account"}, {"password", "xingzhe.password"}, {"sessionId", "xingzhe.session"}}
      : std::vector<std::pair<const char*, const char*>>{{"account", "onelap.account"}, {"password", "onelap.password"}, {"token", "onelap.token"}, {"uid", "onelap.uid"}};
    for (const auto& field : fields) {
      if (!RequiredText(call, field.first, &next[field.second])) { Invalid(result); return; }
    }
    if (strava) {
      const Value* input = Argument(call, "expiresAtSeconds");
      const double* expiry = input ? std::get_if<double>(input) : nullptr;
      if (!expiry || !std::isfinite(*expiry) || *expiry <= 0) { Invalid(result); return; }
      std::ostringstream encoded_expiry;
      encoded_expiry.imbue(std::locale::classic());
      encoded_expiry << std::setprecision(std::numeric_limits<double>::max_digits10) << *expiry;
      next["strava.expiresAt"] = encoded_expiry.str();
    } else if (vault == "onelap") {
      // Persist only this authorization's refresh token under the legacy key.
      // Omission/null clears it, preventing a login from mixing another account's
      // old refresh token with the new credentials. Rust owns rotation fallback.
      const Value* refresh = Argument(call, "refreshToken");
      if (refresh && !std::holds_alternative<std::monostate>(*refresh)) {
        if (!RequiredText(call, "refreshToken", &next["onelap.refresh"])) { Invalid(result); return; }
      }
    }
    if (WriteVault(vault, next, result)) result->Success();
    return;
  }
  if (method == vault + "Status") {
    Map payload;
    if (strava) {
      payload = {{Value("clientId"), Value(Stored(state, "strava.clientId"))},
        {Value("hasClientSecret"), Value(Present(state, "strava.clientSecret"))},
        {Value("hasAccessToken"), Value(Present(state, "strava.accessToken"))},
        {Value("hasRefreshToken"), Value(Present(state, "strava.refreshToken"))},
        {Value("expiresAtSeconds"), Value(Expiry(state))}};
    } else {
      payload = {{Value("hasAccount"), Value(Present(state, vault + ".account"))},
                 {Value("hasPassword"), Value(Present(state, vault + ".password"))}};
      if (vault == "xingzhe") payload[Value("hasSessionId")] = Value(Present(state, "xingzhe.session"));
      else {
        payload[Value("hasToken")] = Value(Present(state, "onelap.token"));
        payload[Value("hasUid")] = Value(Present(state, "onelap.uid"));
      }
    }
    result->Success(Value(payload)); return;
  }
  Map payload;
  if (strava) {
    const auto* purpose = Text(call, "purpose");
    if (!purpose || (*purpose != "refresh" && *purpose != "upload")) { Invalid(result); return; }
    const std::vector<std::pair<const char*, const char*>> fields = *purpose == "refresh"
      ? std::vector<std::pair<const char*, const char*>>{{"clientId", "strava.clientId"}, {"clientSecret", "strava.clientSecret"}, {"refreshToken", "strava.refreshToken"}}
      : std::vector<std::pair<const char*, const char*>>{{"accessToken", "strava.accessToken"}};
    if (Expiry(state) <= 0) { result->Error("strava_not_configured", "Strava authorization is not configured"); return; }
    for (const auto& field : fields) {
      if (!Present(state, field.second)) { result->Error("strava_not_configured", "Strava authorization is not configured"); return; }
      payload[Value(field.first)] = Value(Stored(state, field.second));
    }
    payload[Value("expiresAtSeconds")] = Value(Expiry(state));
  } else {
    if (!Present(state, vault + ".account") || !Present(state, vault + ".password")) {
      result->Error(vault + "_not_configured", "Source authorization is not configured"); return;
    }
    payload[Value("account")] = Value(Stored(state, vault + ".account"));
    payload[Value("password")] = Value(Stored(state, vault + ".password"));
    if (vault == "xingzhe" && Present(state, "xingzhe.session")) payload[Value("sessionId")] = Value(Stored(state, "xingzhe.session"));
    if (vault == "onelap") {
      if (Present(state, "onelap.token") && Present(state, "onelap.uid")) {
        payload[Value("token")] = Value(Stored(state, "onelap.token"));
        payload[Value("uid")] = Value(Stored(state, "onelap.uid"));
      }
      if (Present(state, "onelap.refresh")) payload[Value("refreshToken")] = Value(Stored(state, "onelap.refresh"));
    }
  }
  result->Success(Value(payload));
}

bool EncodePreference(const Value& value, Bytes* bytes) {
  if (const auto* boolean = std::get_if<bool>(&value)) return native_channels::EncodeScalar(*boolean, bytes);
  if (const auto* text = std::get_if<std::string>(&value)) return native_channels::EncodeScalar(*text, bytes);
  if (const auto* integer = std::get_if<int32_t>(&value)) return native_channels::EncodeScalar(static_cast<int64_t>(*integer), bytes);
  if (const auto* integer = std::get_if<int64_t>(&value)) return native_channels::EncodeScalar(*integer, bytes);
  if (const auto* number = std::get_if<double>(&value)) return native_channels::EncodeScalar(*number, bytes);
  return false;
}
bool DecodePreference(const Bytes& bytes, Value* value) {
  native_channels::Scalar scalar;
  if (!native_channels::DecodeScalar(bytes, &scalar)) return false;
  std::visit([value](const auto& item) { *value = Value(item); }, scalar);
  return true;
}
void HandlePreferences(const Call& call, Result* result) {
  const auto& method = call.method_name();
  if (method != "read" && method != "write" && method != "delete") { result->NotImplemented(); return; }
  const auto* key = Text(call, "key");
  if (!key || !native_channels::IsPreferenceKey(*key)) { Invalid(result); return; }
  Bytes bytes;
  if (method == "write") {
    const Value* value = Argument(call, "value");
    if (!value || !EncodePreference(*value, &bytes)) { Invalid(result); return; }
  }
  Failure error;
  PrivateStorage storage;
  if (!storage.Prepare(L"preferences", &error)) { error.Reply(result); return; }
  const auto filename = Wide(*key) + L".pref";
  if (method == "read") {
    if (!storage.Read(filename, native_channels::kPreferenceLimit, &bytes, &error)) {
      if (error.code == "sync_file_missing") result->Success(); else error.Reply(result);
      return;
    }
    Value value;
    if (!DecodePreference(bytes, &value)) { result->Error("preferences_invalid_data", "Stored preference has an unsupported value"); return; }
    result->Success(value); return;
  }
  if (!(method == "write" ? storage.Write(filename, bytes, &error) : storage.Delete(filename, &error))) { error.Reply(result); return; }
  result->Success();
}

void HandleSyncFiles(const Call& call, Result* result) {
  const auto& method = call.method_name();
  std::wstring directory, filename;
  size_t limit;
  bool json;
  if (method == "readBatchSession" || method == "writeBatchSession" || method == "deleteBatchSession") {
    filename = L"auto-sync-batch.json"; limit = 4 * 1024 * 1024; json = true;
  } else if (method == "readState" || method == "writeState" || method == "deleteState") {
    filename = L"sync_state.json"; limit = native_channels::kStateLimit; json = true;
  } else if (native_channels::IsHealthPreparedFitMethod(method) || method == "readSyncedFit" || method == "writeSyncedFit" || method == "deleteSyncedFit" ||
             method == "readRecovery" || method == "writeRecovery" || method == "deleteRecovery") {
    const auto* fingerprint = Text(call, "fingerprint");
    if (!fingerprint || !native_channels::IsFingerprint(*fingerprint)) { Invalid(result); return; }
    json = method.find("Recovery") != std::string::npos;
    directory = native_channels::IsHealthPreparedFitMethod(method) ? L"health_prepared" : (json ? L"pending_resync" : L"synced_fits");
    filename = Wide(*fingerprint) + (json ? L".json" : L".fit");
    limit = json ? native_channels::kRecoveryLimit : native_channels::kFitLimit;
  } else { result->NotImplemented(); return; }
  const bool writing = method.compare(0, 5, "write") == 0;
  const Bytes* bytes = nullptr;
  if (writing) {
    const Value* input = Argument(call, "bytes");
    bytes = input ? std::get_if<Bytes>(input) : nullptr;
    if (!bytes || bytes->empty()) { Invalid(result); return; }
    if (bytes->size() > limit) { result->Error("sync_file_too_large", "The sync file exceeds its size limit"); return; }
    if (json && !native_channels::IsJsonObject(*bytes)) { result->Error("invalid_json", "A valid JSON object is required"); return; }
  }
  Failure error;
  PrivateStorage storage;
  if (!storage.Prepare(directory, &error)) { error.Reply(result); return; }
  if (method.compare(0, 4, "read") == 0) {
    Bytes data;
    if (!storage.Read(filename, limit, &data, &error)) { error.Reply(result); return; }
    if (json && !native_channels::IsJsonObject(data)) {
      if (!storage.Quarantine(filename, &error)) { error.Reply(result); return; }
      result->Error("sync_file_corrupt", "The invalid JSON sync file was quarantined"); return;
    }
    result->Success(Value(std::move(data))); return;
  }
  if (!(writing ? storage.Write(filename, *bytes, &error) : storage.Delete(filename, &error))) { error.Reply(result); return; }
  result->Success();
}

void PickFits(HWND window, bool* picker_open, Result* result) {
  if (*picker_open) { result->Error("file_picker_busy", "A file picker is already open"); return; }
  *picker_open = true;
  struct ResetFlag { bool* flag; ~ResetFlag() { *flag = false; } } reset{picker_open};
  ComPtr<IFileOpenDialog> picker;
  HRESULT status = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(picker.GetAddressOf()));
  FILEOPENDIALOGOPTIONS options = 0;
  const COMDLG_FILTERSPEC types[] = {{L"FIT activity files (*.fit)", L"*.fit"}};
  if (SUCCEEDED(status)) status = picker->GetOptions(&options);
  if (SUCCEEDED(status)) status = picker->SetOptions(options | FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST | FOS_FORCEFILESYSTEM);
  if (SUCCEEDED(status)) status = picker->SetFileTypes(1, types);
  if (SUCCEEDED(status)) status = picker->SetTitle(L"Import FIT activities");
  if (SUCCEEDED(status)) status = picker->Show(window);
  if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(Value(flutter::EncodableList())); return; }
  ComPtr<IShellItemArray> selected;
  if (SUCCEEDED(status)) status = picker->GetResults(selected.GetAddressOf());
  DWORD count = 0;
  if (SUCCEEDED(status)) status = selected->GetCount(&count);
  if (FAILED(status)) { result->Error("file_picker_failed", "Windows could not open the FIT file picker"); return; }
  if (count > 128) { result->Error("file_picker_too_many", "Select at most 128 FIT files at a time"); return; }
  flutter::EncodableList paths;
  for (DWORD index = 0; index < count; ++index) {
    ComPtr<IShellItem> item;
    PWSTR raw_path = nullptr;
    if (FAILED(selected->GetItemAt(index, item.GetAddressOf())) || FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path))) {
      result->Error("file_picker_failed", "A selected file could not be accessed"); return;
    }
    std::wstring path(raw_path);
    CoTaskMemFree(raw_path);
    if (path.size() < 4 || _wcsicmp(path.c_str() + path.size() - 4, L".fit") != 0) {
      result->Error("invalid_fit_file", "Only FIT files may be imported"); return;
    }
    Handle file(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    BY_HANDLE_FILE_INFORMATION info = {};
    LARGE_INTEGER size = {};
    if (!file.valid() || !GetFileInformationByHandle(file.get(), &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        !GetFileSizeEx(file.get(), &size) || size.QuadPart <= 0 ||
        static_cast<uint64_t>(size.QuadPart) > native_channels::kFitLimit) {
      result->Error("invalid_fit_file", "Selected FIT files must be ordinary files between 1 byte and 64 MiB"); return;
    }
    const auto utf8 = Utf8(path);
    if (utf8.empty()) { result->Error("invalid_fit_file", "The selected filename is not valid Unicode"); return; }
    paths.emplace_back(utf8);
  }
  result->Success(Value(paths));
}

}  // namespace

NativeChannels::NativeChannels(flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  const auto add = [&](const char* name, std::function<void(const Call&, Result*)> handler) {
    auto channel = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      std::string("health_workout_export/") + name, &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([handler](const Call& call, std::unique_ptr<Result> result) { handler(call, result.get()); });
    channels_.push_back(std::move(channel));
  };
  add("keychain", [](const Call& call, Result* result) { HandleVault(call, result, true); });
  add("third_party_vault", [](const Call& call, Result* result) { HandleVault(call, result, false); });
  add("preferences", HandlePreferences);
  add("sync_files", HandleSyncFiles);
  add("files", [this](const Call& call, Result* result) {
    if (call.method_name() == "pickFits") PickFits(window_, &picker_open_, result); else result->NotImplemented();
  });
  add("healthkit", [](const Call& call, Result* result) {
    if (call.method_name() == "isAvailable") { result->Success(Value(false)); return; }
    if (call.method_name() == "requestAuthorization" || call.method_name() == "listWorkouts" ||
        call.method_name() == "fetchWorkoutBundles" || call.method_name() == "openSettings") {
      result->Error("healthkit_unavailable", "Windows does not provide HealthKit; import FIT files instead"); return;
    }
    if (call.method_name() == "currentTimeZoneIdentifier") {
      const auto identifier = CurrentIanaTimeZone();
      if (identifier.empty()) result->Error("timezone_unavailable", "Windows ICU could not resolve the configured time zone");
      else result->Success(Value(identifier));
      return;
    }
    result->NotImplemented();
  });
  web_plugin_ = std::make_unique<StravaWebPlugin>(window_, [](std::wstring* directory) {
    PrivateStorage storage;
    Failure error;
    if (!storage.Prepare(L"webview2", &error)) return false;
    *directory = storage.directory();
    return true;
  });
  auto web_channel = std::make_unique<flutter::MethodChannel<Value>>(messenger,
    "health_workout_export/strava_web", &flutter::StandardMethodCodec::GetInstance());
  web_channel->SetMethodCallHandler([this](const Call& call, std::unique_ptr<Result> result) {
    web_plugin_->Handle(call, std::move(result));
  });
  channels_.push_back(std::move(web_channel));
  oauth_plugin_ = std::make_unique<StravaOAuthPlugin>(window_);
  auto oauth_channel = std::make_unique<flutter::MethodChannel<Value>>(messenger,
    "health_workout_export/strava_oauth", &flutter::StandardMethodCodec::GetInstance());
  oauth_channel->SetMethodCallHandler([this](const Call& call, std::unique_ptr<Result> result) {
    oauth_plugin_->Handle(call, std::move(result));
  });
  channels_.push_back(std::move(oauth_channel));
}
NativeChannels::~NativeChannels() {
  for (const auto& channel : channels_) channel->SetMethodCallHandler(nullptr);
}
