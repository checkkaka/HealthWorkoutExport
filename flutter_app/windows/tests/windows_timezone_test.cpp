#include "../runner/windows_timezone.h"
#include <iostream>
int main() {
  const auto zone = CurrentIanaTimeZone();
  if (zone.empty() || zone.find(' ') != std::string::npos || zone.find('/') == std::string::npos) {
    std::cerr << "Windows ICU did not resolve a valid IANA zone\n";
    return 1;
  }
  std::cout << "Windows ICU timezone mapping passed\n";
  return 0;
}
