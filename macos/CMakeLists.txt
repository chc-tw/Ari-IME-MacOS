# SPDX-License-Identifier: GPL-3.0-or-later
# macOS build for Ari IME.
#
# The root CMakeLists.txt targets Fcitx5 and cannot be configured on macOS, so
# this is a separate project root (same arrangement as wasm/). It reuses the
# platform-neutral core in src/ unchanged, compiled against the fcitx
# compatibility shims in compat/include and a macOS user_data implementation.
cmake_minimum_required(VERSION 3.24)
project(ari_ime_macos VERSION 2.5.2 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
endif()

set(ARI_SOURCE_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")

set(CHEWING_INCLUDE_DIR "" CACHE PATH
    "Directory containing libchewing's chewing.h")
set(CHEWING_LIBRARY "" CACHE FILEPATH
    "Path to the libchewing static library")
set(CHEWING_DATA_DIR "" CACHE PATH
    "Directory containing libchewing's built dictionary files")

if(NOT CHEWING_INCLUDE_DIR OR NOT CHEWING_LIBRARY)
    message(FATAL_ERROR
        "Set CHEWING_INCLUDE_DIR and CHEWING_LIBRARY. Run "
        "macos/build-libchewing.sh first.")
endif()

# --- Core: src/ verbatim, plus the macOS data-location implementation. -------
add_library(ari-core STATIC
    "${ARI_SOURCE_ROOT}/src/layout.cpp"
    "${ARI_SOURCE_ROOT}/src/zhuyin.cpp"
    "${ARI_SOURCE_ROOT}/src/buffer.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/user_data.mm"
)
target_include_directories(ari-core
    BEFORE PUBLIC
        "${ARI_SOURCE_ROOT}/compat/include"
        "${ARI_SOURCE_ROOT}/src"
        "${CHEWING_INCLUDE_DIR}"
)
target_compile_options(ari-core PRIVATE -Wall -Wextra -Wpedantic
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_link_libraries(ari-core
    PUBLIC "${CHEWING_LIBRARY}"
    PRIVATE "-framework Foundation"
)

# --- Portable personal-dictionary tool (identical source to the Linux build).
add_executable(ari-ime-dict "${ARI_SOURCE_ROOT}/src/dict_tool.cpp")
target_link_libraries(ari-ime-dict PRIVATE ari-core)
target_compile_definitions(ari-ime-dict
    PRIVATE ARI_IME_CHEWING_VERSION="${CHEWING_VERSION}")
target_compile_options(ari-ime-dict PRIVATE -Wall -Wextra -Wpedantic)

# --- The input method bundle -------------------------------------------------
set(ARI_BUNDLE_ID "io.github.chctw.inputmethod.AriIME" CACHE STRING
    "Bundle identifier for the input method app")
configure_file("${CMAKE_CURRENT_LIST_DIR}/Info.plist.in"
               "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

add_executable(AriIME MACOSX_BUNDLE
    "${CMAKE_CURRENT_LIST_DIR}/AriApp.mm"
    "${CMAKE_CURRENT_LIST_DIR}/AriInputController.mm"
    "${CMAKE_CURRENT_LIST_DIR}/AriCandidateWindow.mm"
    "${CMAKE_CURRENT_LIST_DIR}/AriHUD.mm"
    "${CMAKE_CURRENT_LIST_DIR}/AriPreferences.mm"
    "${CMAKE_CURRENT_LIST_DIR}/AriPreferencesWindow.mm"
    "${CMAKE_CURRENT_LIST_DIR}/KeyMap.mm"
)
target_link_libraries(AriIME PRIVATE ari-core
    "-framework Cocoa" "-framework Carbon" "-framework InputMethodKit")
set_source_files_properties("${CMAKE_CURRENT_LIST_DIR}/ari.tiff" PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources)
target_sources(AriIME PRIVATE "${CMAKE_CURRENT_LIST_DIR}/ari.tiff")
target_compile_options(AriIME PRIVATE -Wall -Wextra
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(AriIME PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist")

# Classic bundles are expected to carry PkgInfo alongside Info.plist; Text
# Input Services reads the creator code from it.
add_custom_command(TARGET AriIME POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E echo_append "APPLARIM"
        > "$<TARGET_BUNDLE_DIR:AriIME>/Contents/PkgInfo"
    VERBATIM)

# libchewing's dictionaries ship inside the bundle; user_data.mm points
# CHEWING_PATH at them (there is no /usr/share/libchewing on macOS).
if(CHEWING_DATA_DIR)
    file(GLOB ARI_CHEWING_DATA "${CHEWING_DATA_DIR}/*.dat")
    if(NOT ARI_CHEWING_DATA)
        message(FATAL_ERROR "CHEWING_DATA_DIR has no .dat files: ${CHEWING_DATA_DIR}")
    endif()
    target_sources(AriIME PRIVATE ${ARI_CHEWING_DATA})
    set_source_files_properties(${ARI_CHEWING_DATA} PROPERTIES
        MACOSX_PACKAGE_LOCATION Resources)
else()
    message(WARNING
        "CHEWING_DATA_DIR is not set; AriIME.app will have no dictionaries")
endif()

# --- Coverage ---------------------------------------------------------------
option(ARI_ENABLE_COVERAGE "Build with llvm-cov instrumentation" OFF)
if(ARI_ENABLE_COVERAGE)
    target_compile_options(ari-core PUBLIC
        -fprofile-instr-generate -fcoverage-mapping -O0 -g)
    target_link_options(ari-core PUBLIC
        -fprofile-instr-generate -fcoverage-mapping)
endif()

# --- Maintainer-only local tests --------------------------------------------
# test/ is untracked upstream (see .gitignore). Restore it with:
#   git checkout 317ecb2^ -- test wasm/test
set(ARI_TEST_DIR "${ARI_SOURCE_ROOT}/test")
set(ARI_LOCAL_TESTS_AVAILABLE TRUE)
foreach(ari_local_test IN ITEMS
        test_buffer.cpp test_layout.cpp test_user_data.cpp test_dict_tool.sh)
    if(NOT EXISTS "${ARI_TEST_DIR}/${ari_local_test}")
        set(ARI_LOCAL_TESTS_AVAILABLE FALSE)
    endif()
endforeach()

include(CTest)
if(BUILD_TESTING AND NOT ARI_LOCAL_TESTS_AVAILABLE)
    message(WARNING
        "BUILD_TESTING=ON but maintainer-only test sources are absent; "
        "local tests are disabled")
elseif(BUILD_TESTING)
    if(NOT CHEWING_DATA_DIR)
        message(FATAL_ERROR
            "BUILD_TESTING requires CHEWING_DATA_DIR (libchewing's built "
            "dictionaries) so tests can find the system dictionary")
    endif()

    function(ari_add_core_test name source)
        add_executable(${name} "${ARI_TEST_DIR}/${source}")
        target_include_directories(${name} PRIVATE "${ARI_TEST_DIR}")
        target_link_libraries(${name} PRIVATE ari-core)
        target_compile_options(${name} PRIVATE -Wall -Wextra -Wpedantic)
        add_test(NAME ${name} COMMAND ${name})
        # macOS has no compiled-in system dictionary path, and the sandboxed
        # test harness deliberately clears HOME/XDG. Point libchewing at the
        # build's own dictionaries explicitly.
        set_tests_properties(${name} PROPERTIES
            ENVIRONMENT "CHEWING_PATH=${CHEWING_DATA_DIR}")
    endfunction()

    # macOS frontend tests live in macos/test/ (tracked), unlike the upstream
    # maintainer-only test/ directory.
    add_library(ari-frontend STATIC
        "${CMAKE_CURRENT_LIST_DIR}/KeyMap.mm"
        "${CMAKE_CURRENT_LIST_DIR}/AriInputController.mm"
        "${CMAKE_CURRENT_LIST_DIR}/AriCandidateWindow.mm"
        "${CMAKE_CURRENT_LIST_DIR}/AriHUD.mm"
        "${CMAKE_CURRENT_LIST_DIR}/AriPreferences.mm"
        "${CMAKE_CURRENT_LIST_DIR}/AriPreferencesWindow.mm")

    target_include_directories(ari-frontend PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
    target_link_libraries(ari-frontend PUBLIC ari-core
        "-framework Cocoa" "-framework Carbon" "-framework InputMethodKit")
    target_compile_options(ari-frontend PRIVATE -Wall -Wextra
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)

    function(ari_add_frontend_test name source)
        add_executable(${name} "${CMAKE_CURRENT_LIST_DIR}/test/${source}")
        target_link_libraries(${name} PRIVATE ari-frontend)
        target_compile_options(${name} PRIVATE -Wall -Wextra
            $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
        add_test(NAME ${name} COMMAND ${name})
        set_tests_properties(${name} PROPERTIES
            ENVIRONMENT "CHEWING_PATH=${CHEWING_DATA_DIR}")
    endfunction()

    ari_add_frontend_test(test_keymap test_keymap.mm)
    ari_add_frontend_test(test_preferences test_preferences.mm)
    ari_add_frontend_test(test_preferences_window test_preferences_window.mm)
    ari_add_frontend_test(test_mixed_input test_mixed_input.mm)
    ari_add_frontend_test(test_controller test_controller.mm)

    ari_add_core_test(test_buffer test_buffer.cpp)
    ari_add_core_test(test_layout test_layout.cpp)
    ari_add_core_test(test_user_data test_user_data.cpp)

    add_test(NAME dict_tool
        COMMAND bash "${ARI_TEST_DIR}/test_dict_tool.sh"
                "$<TARGET_FILE:ari-ime-dict>")
    set_tests_properties(dict_tool PROPERTIES
        ENVIRONMENT "CHEWING_PATH=${CHEWING_DATA_DIR}")
endif()
