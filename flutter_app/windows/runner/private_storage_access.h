#pragma once

#include <windows.h>

namespace native_channels {
// SetSecurityInfo may inspect the existing descriptor while applying a protected
// DACL. Keep the rights local to this handle; the user+SYSTEM DACL is unchanged.
inline constexpr DWORD kPrivateDirectoryAccess =
    FILE_READ_ATTRIBUTES | READ_CONTROL | WRITE_DAC;
}
