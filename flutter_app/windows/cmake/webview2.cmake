# Pinned official Microsoft WebView2 SDK. The Evergreen browser runtime remains
# an OS prerequisite and is never installed or silently downloaded by this app.
include(FetchContent)
set(HWE_WEBVIEW2_SDK_DIR "" CACHE PATH "Pre-extracted Microsoft.Web.WebView2 1.0.2903.40 NuGet package")
if(NOT HWE_WEBVIEW2_SDK_DIR)
  FetchContent_Declare(hwe_webview2_sdk
    URL "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.2903.40/microsoft.web.webview2.1.0.2903.40.nupkg"
    DOWNLOAD_NAME "webview2-sdk.zip"
    TLS_VERIFY TRUE
  )
  FetchContent_GetProperties(hwe_webview2_sdk)
  if(NOT hwe_webview2_sdk_POPULATED)
    FetchContent_Populate(hwe_webview2_sdk)
  endif()
  set(HWE_WEBVIEW2_SDK_DIR "${hwe_webview2_sdk_SOURCE_DIR}")
endif()
if(NOT EXISTS "${HWE_WEBVIEW2_SDK_DIR}/build/native/include/WebView2.h")
  message(FATAL_ERROR "HWE_WEBVIEW2_SDK_DIR must contain the official Microsoft.Web.WebView2 SDK")
endif()
function(hwe_link_webview2 target)
  if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64" OR CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$")
    set(webview2_arch "arm64")
  elseif(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(webview2_arch "x64")
  else()
    set(webview2_arch "x86")
  endif()
  target_include_directories(${target} SYSTEM PRIVATE "${HWE_WEBVIEW2_SDK_DIR}/build/native/include")
  target_link_libraries(${target} PRIVATE
    "${HWE_WEBVIEW2_SDK_DIR}/build/native/${webview2_arch}/WebView2LoaderStatic.lib"
    winhttp.lib version.lib shlwapi.lib ole32.lib shell32.lib user32.lib)
endfunction()
