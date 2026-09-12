cmake_minimum_required(VERSION 3.14)
project(ssrvpn_physical_latency_tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(RUNNER "${CMAKE_CURRENT_LIST_DIR}/../../SSRVPN_Windows/windows/runner")
add_executable(dns_http_response_test "${RUNNER}/dns_http_response_test.cpp")
if(MSVC)
  target_compile_options(dns_http_response_test PRIVATE /W4 /WX /UNDEBUG)
  add_executable(physical_latency_test
    "${RUNNER}/physical_tcp_latency_probe.cpp"
    "${RUNNER}/physical_dns.cpp"
    "${RUNNER}/physical_tcp_latency_probe_test.cpp")
  target_compile_options(physical_latency_test PRIVATE /W4 /WX /utf-8)
  target_compile_definitions(physical_latency_test PRIVATE NOMINMAX UNICODE _UNICODE)
  target_link_libraries(physical_latency_test PRIVATE ws2_32 iphlpapi dnsapi secur32 normaliz fwpuclnt)
else()
  target_compile_options(dns_http_response_test PRIVATE -Wall -Wextra -Werror -UNDEBUG)
endif()
