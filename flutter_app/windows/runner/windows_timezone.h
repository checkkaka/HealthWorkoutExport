#ifndef RUNNER_WINDOWS_TIMEZONE_H_
#define RUNNER_WINDOWS_TIMEZONE_H_
#include <string>

// Returns the OS ICU/CLDR representative IANA zone for the configured Windows
// time-zone key, or an empty string when the OS mapping cannot be established.
std::string CurrentIanaTimeZone();
#endif
