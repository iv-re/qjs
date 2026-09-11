cmake_minimum_required(VERSION 3.10)
project(qjs_dart C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(qjs_dart SHARED
    quickjs/dtoa.c
    quickjs/libregexp.c
    quickjs/libunicode.c
    quickjs/quickjs.c
    src/qjs_dart.c
)

target_include_directories(qjs_dart PUBLIC
    quickjs
    src
)

target_compile_definitions(qjs_dart PRIVATE
    _GNU_SOURCE=1
    CONFIG_VERSION="0.16.2"
    QUICKJS_NG_BUILD=1
    NDEBUG=1
)

if(MSVC)
  target_compile_options(qjs_dart PRIVATE
      /O2
      /W3
      -wd4068
      -wd4200
      -wd4201
      -wd4267
  )
else()
  target_compile_options(qjs_dart PRIVATE
      -O3
      -fomit-frame-pointer
      -ffunction-sections
      -fdata-sections
  )
endif()

if(WIN32)
  set_target_properties(qjs_dart PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
  target_link_options(qjs_dart PRIVATE "/OPT:REF" "/OPT:ICF")
endif()

if(APPLE)
  target_link_libraries(qjs_dart PRIVATE pthread m)
  target_link_options(qjs_dart PRIVATE "-Wl,-dead_strip")
elseif(ANDROID)
  target_link_libraries(qjs_dart PRIVATE m dl log)
  target_link_options(qjs_dart PRIVATE "-Wl,-s" "-Wl,--gc-sections")
elseif(UNIX)
  target_link_libraries(qjs_dart PRIVATE pthread m dl)
  target_link_options(qjs_dart PRIVATE "-Wl,-s" "-Wl,--gc-sections")
endif()

message(STATUS "Project ${PROJECT_NAME} configured")
