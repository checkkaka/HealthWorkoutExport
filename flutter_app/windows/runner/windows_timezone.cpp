#include "windows_timezone.h"
#include <windows.h>
#include <cstdint>
#include <cstring>

std::string CurrentIanaTimeZone() {
  DYNAMIC_TIME_ZONE_INFORMATION zone = {};
  if (GetDynamicTimeZoneInformation(&zone) == TIME_ZONE_ID_INVALID || zone.TimeZoneKeyName[0] == L'\0') return {};
  // ICU is part of Windows 10 1703+. 1903+ consolidates the APIs in icu.dll;
  // earlier supported systems expose the same C API from icuin.dll. Load only
  // from System32, never from the application directory or an arbitrary PATH.
  HMODULE icu = LoadLibraryExW(L"icu.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!icu) icu = LoadLibraryExW(L"icuin.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!icu) return {};
  using MapZone = int32_t(__cdecl*)(const char16_t*, int32_t, const char*, char16_t*, int32_t, int32_t*);
  const auto procedure = GetProcAddress(icu, "ucal_getTimeZoneIDForWindowsID");
  MapZone map_zone = nullptr;
  static_assert(sizeof(map_zone) == sizeof(procedure));
  std::memcpy(&map_zone, &procedure, sizeof(map_zone));
  char16_t mapped[256] = {};
  int32_t status = 0;
  // nullptr uses CLDR territory 001 (the canonical representative for that
  // Windows rule set), independent of an unrelated display language/region.
  const int32_t length = map_zone ? map_zone(reinterpret_cast<const char16_t*>(zone.TimeZoneKeyName), -1,
    nullptr, mapped, 256, &status) : 0;
  FreeLibrary(icu);
  if (status > 0 || length <= 0 || length >= 256) return {};
  std::string result;
  for (int32_t i = 0; i < length; ++i) {
    const char16_t c = mapped[i];
    if (!((c >= u'A' && c <= u'Z') || (c >= u'a' && c <= u'z') || (c >= u'0' && c <= u'9') ||
        c == u'/' || c == u'_' || c == u'-' || c == u'+')) return {};
    result += static_cast<char>(c);
  }
  return result;
}
