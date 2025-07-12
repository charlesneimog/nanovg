cmake_minimum_required(VERSION 3.15)
cmake_policy(SET CMP0063 NEW)

project(nanovg)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT EMSCRIPTEN)
    message(FATAL_ERROR "Only emscripten supported")
endif()

add_library(
    nanovg STATIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src/nanovg.cpp ${CMAKE_CURRENT_SOURCE_DIR}/src/nanovg.h
    ${CMAKE_CURRENT_SOURCE_DIR}/src/nanovg_gl.h ${CMAKE_CURRENT_SOURCE_DIR}/src/nanovg_gl_utils.h)

if(BUILD_EXAMPLES)
    add_executable(main ${CMAKE_CURRENT_SOURCE_DIR}/example/example_webgl.cpp)
    target_include_directories(main PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")
    target_link_options(main PUBLIC -sUSE_WEBGL2=1 -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2
                        -sALLOW_MEMORY_GROWTH)
    target_link_libraries(main nanovg)
    add_custom_command(
        TARGET main
        POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/example/index.html"
                "$<TARGET_FILE_DIR:main>/index.html")

endif()
