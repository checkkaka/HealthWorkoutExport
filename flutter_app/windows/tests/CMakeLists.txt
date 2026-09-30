cmake_minimum_required(VERSION 3.14)
project(windows_native_validation LANGUAGES CXX)
enable_testing()

function(hwe_native_settings target)
  target_compile_features(${target} PRIVATE cxx_std_17)
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4 /WX /EHsc /utf-8)
    target_compile_definitions(${target} PRIVATE NOMINMAX UNICODE _UNICODE _HAS_EXCEPTIONS=0)
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra -Werror -pedantic)
  endif()
endfunction()

foreach(test_name native_channel_validation strava_web oauth_validation)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${test_name}_test.cpp")
    add_executable(${test_name}_test "${test_name}_test.cpp")
    hwe_native_settings(${test_name}_test)
    add_test(NAME ${test_name} COMMAND ${test_name}_test)
  endif()
endforeach()

# Independent real-MSVC adapter compilation. Only the Flutter C++ header source
# checkout is needed; no flutter command, pub resolution, Dart build or FRB codegen.
option(HWE_COMPILE_WINDOWS_ADAPTERS "Compile the production Win32 adapter sources" ${WIN32})
set(HWE_FLUTTER_SOURCE_DIR "" CACHE PATH "Official Flutter source checkout (3.47.5)")
if(WIN32 AND HWE_COMPILE_WINDOWS_ADAPTERS)
  set(flutter_client "${HWE_FLUTTER_SOURCE_DIR}/engine/src/flutter/shell/platform/common/client_wrapper/include")
  if(NOT EXISTS "${flutter_client}/flutter/encodable_value.h")
    message(FATAL_ERROR "Set HWE_FLUTTER_SOURCE_DIR to an official Flutter source checkout containing engine client-wrapper headers")
  endif()
  add_library(windows_native_adapters STATIC
    ../runner/native_channels.cpp
    ../runner/strava_web_plugin.cpp
    ../runner/windows_timezone.cpp
  )
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../runner/strava_oauth.cpp")
    target_sources(windows_native_adapters PRIVATE ../runner/strava_oauth.cpp)
  endif()
  hwe_native_settings(windows_native_adapters)
  target_include_directories(windows_native_adapters SYSTEM PRIVATE "${flutter_client}")
  include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/webview2.cmake")
  hwe_link_webview2(windows_native_adapters)
  target_link_libraries(windows_native_adapters PRIVATE advapi32.lib uuid.lib bcrypt.lib ws2_32.lib)

  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../runner/strava_oauth.cpp")
    add_executable(windows_async_adapter_test windows_async_adapter_test.cpp)
    hwe_native_settings(windows_async_adapter_test)
    target_include_directories(windows_async_adapter_test SYSTEM PRIVATE "${flutter_client}")
    target_link_libraries(windows_async_adapter_test PRIVATE windows_native_adapters)
    add_test(NAME windows_async_adapters COMMAND windows_async_adapter_test)
  endif()

  add_executable(windows_timezone_test windows_timezone_test.cpp ../runner/windows_timezone.cpp)
  hwe_native_settings(windows_timezone_test)
  add_test(NAME windows_icu_timezone COMMAND windows_timezone_test)
endif()
