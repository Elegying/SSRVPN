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
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# A tiny outer launcher keeps the portable root stable while the Flutter
# executable and its runtime dependencies live under bin/. It forwards the
# command line and preserves the operating system's security mitigations.
set(LAUNCHER_TARGET "${BINARY_NAME}_launcher")
add_executable(${LAUNCHER_TARGET} WIN32
  "launcher_main.cpp"
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

# CET (Control-flow Enforcement Technology) compatibility.
# /guard:cf generates CET-safe machine code.
# Post-build: patch CET_COMPAT (0x1000) PE flag since the linker's
# /CETCOMPAT silently drops when non-code inputs (Runner.res) lack CET metadata.
# We inline the PowerShell rather than use -File to avoid CMake path-resolution
# issues with relative paths across generator boundaries.
target_compile_options(${LAUNCHER_TARGET} PRIVATE "/guard:cf")
add_custom_command(TARGET ${LAUNCHER_TARGET} POST_BUILD
  COMMAND powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass
    -Command "$bytes=[IO.File]::ReadAllBytes('$<TARGET_FILE:${LAUNCHER_TARGET}>');$off=[BitConverter]::ToInt32($bytes,0x3C)+94;$c=[BitConverter]::ToUInt16($bytes,$off);$c=$c -bor 0x1000;[BitConverter]::GetBytes($c).CopyTo($bytes,$off);[IO.File]::WriteAllBytes('$<TARGET_FILE:${LAUNCHER_TARGET}>',$bytes);Write-Output ('CET_COMPAT: 0x{0:X3} -> 0x{1:X4}' -f ($c -bxor 0x1000),$c)"
  COMMENT "Patching CET_COMPAT PE flag")
