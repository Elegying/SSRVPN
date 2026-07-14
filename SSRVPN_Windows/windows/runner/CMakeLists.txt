cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "startup_diagnostics.cpp"
  "system_proxy_recovery.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "dbghelp.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "wininet.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# A tiny outer launcher keeps the portable root stable while the Flutter
# executable and its runtime dependencies live under bin/. It forwards the
# command line and preserves the operating system's security mitigations.
set(LAUNCHER_TARGET "${BINARY_NAME}_launcher")
add_executable(${LAUNCHER_TARGET} WIN32
  "launcher_main.cpp"
  "system_proxy_recovery.cpp"
  "Runner.rc"
  "runner.exe.manifest"
)
apply_standard_settings(${LAUNCHER_TARGET})
target_compile_definitions(${LAUNCHER_TARGET} PRIVATE "NOMINMAX")
target_compile_definitions(${LAUNCHER_TARGET} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${LAUNCHER_TARGET} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${LAUNCHER_TARGET} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${LAUNCHER_TARGET} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${LAUNCHER_TARGET} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")
target_link_libraries(${LAUNCHER_TARGET} PRIVATE "shell32.lib")
target_link_libraries(${LAUNCHER_TARGET} PRIVATE "advapi32.lib")
target_link_libraries(${LAUNCHER_TARGET} PRIVATE "wininet.lib")

# Use the MSVC compiler and linker switches for control-flow protection. Never
# patch PE DllCharacteristics directly: 0x1000 in that field is AppContainer,
# not CET compatibility, and can make a normal desktop launcher unloadable.
target_compile_options(${LAUNCHER_TARGET} PRIVATE "/guard:cf")
target_link_options(${LAUNCHER_TARGET} PRIVATE "/CETCOMPAT" "/GUARD:CF")
