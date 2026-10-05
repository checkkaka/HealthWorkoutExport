#include "../runner/private_storage_access.h"
#include <aclapi.h>
#include <sddl.h>
#include <objbase.h>
#include <iostream>
#include <string>
#include <vector>

int main() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return 1;
  DWORD count = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &count);
  std::vector<unsigned char> token_info(count);
  if (!GetTokenInformation(token, TokenUser, token_info.data(), count, &count)) {
    CloseHandle(token); return 1;
  }
  CloseHandle(token);
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(token_info.data())->User.Sid, &sid)) return 1;
  const std::wstring sddl = L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + std::wstring(sid) + L")";
  LocalFree(sid);
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) return 1;
  PACL dacl = nullptr;
  BOOL present = FALSE, defaulted = FALSE;
  if (!GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) || !present || !dacl) {
    LocalFree(descriptor); return 1;
  }
  wchar_t root[MAX_PATH] = {};
  if (!GetTempPathW(MAX_PATH, root)) { LocalFree(descriptor); return 1; }
  GUID id;
  wchar_t suffix[40] = {};
  if (FAILED(CoCreateGuid(&id)) || !StringFromGUID2(id, suffix, 40)) { LocalFree(descriptor); return 1; }
  const std::wstring path = std::wstring(root) + L"hwe-acl-test-" + suffix;
  SECURITY_ATTRIBUTES attributes = {static_cast<DWORD>(sizeof(SECURITY_ATTRIBUTES)), descriptor, FALSE};
  if (!CreateDirectoryW(path.c_str(), &attributes)) { LocalFree(descriptor); return 1; }
  bool passed = true;
  for (const DWORD access : {static_cast<DWORD>(FILE_READ_ATTRIBUTES | WRITE_DAC), native_channels::kPrivateDirectoryAccess}) {
    HANDLE directory = CreateFileW(path.c_str(), access, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (directory == INVALID_HANDLE_VALUE) { passed = false; continue; }
    const DWORD status = SetSecurityInfo(directory, SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, dacl, nullptr);
    std::cout << "Private directory handle mask=" << access << " SetSecurityInfo=" << status << "\n";
    if (access == native_channels::kPrivateDirectoryAccess) {
      if (status != ERROR_SUCCESS) passed = false;
      PSECURITY_DESCRIPTOR actual = nullptr;
      PACL actual_dacl = nullptr;
      const DWORD read_status = GetSecurityInfo(directory, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
        nullptr, nullptr, &actual_dacl, nullptr, &actual);
      SECURITY_DESCRIPTOR_CONTROL control = 0;
      DWORD revision = 0;
      if (read_status != ERROR_SUCCESS || actual_dacl == nullptr || actual_dacl->AceCount != 2 ||
          !GetSecurityDescriptorControl(actual, &control, &revision) || !(control & SE_DACL_PROTECTED)) passed = false;
      if (actual_dacl != nullptr && actual_dacl->AceCount == 2) {
        unsigned char system_sid[SECURITY_MAX_SID_SIZE] = {};
        DWORD sid_size = static_cast<DWORD>(sizeof(system_sid));
        if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid, &sid_size)) passed = false;
        for (DWORD index = 0; index < 2; ++index) {
          void* raw = nullptr;
          if (!GetAce(actual_dacl, index, &raw)) { passed = false; continue; }
          const auto* ace = static_cast<ACCESS_ALLOWED_ACE*>(raw);
          PSID expected = index == 0 ? static_cast<PSID>(system_sid)
            : reinterpret_cast<TOKEN_USER*>(token_info.data())->User.Sid;
          if (ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE || ace->Mask != FILE_ALL_ACCESS ||
              !EqualSid(const_cast<DWORD*>(&ace->SidStart), expected)) passed = false;
        }
      }
      if (actual) LocalFree(actual);
    }
    CloseHandle(directory);
  }
  // No weakening: ACL remains protected with only the original two principals.
  LocalFree(descriptor);
  if (!RemoveDirectoryW(path.c_str())) passed = false;
  return passed ? 0 : 1;
}
