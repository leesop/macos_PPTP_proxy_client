cmake_minimum_required(VERSION 3.20)
project(pptp_proxy C)
set(CMAKE_C_STANDARD 11)
set(LWIP_DIR "${CMAKE_CURRENT_LIST_DIR}/../lwip")
include("${LWIP_DIR}/src/Filelists.cmake")
add_executable(pptp-proxy
  main.c
  ${LWIP_DIR}/src/netif/ethernet.c
  ${lwipcore_SRCS}
  ${lwipcore4_SRCS}
  ${lwipppp_SRCS}
)
target_include_directories(pptp-proxy PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}"
  "${LWIP_DIR}/src/include"
  "${LWIP_DIR}/contrib/ports/unix/port/include"
)
target_compile_definitions(pptp-proxy PRIVATE _DARWIN_C_SOURCE)
target_compile_options(pptp-proxy PRIVATE -Wno-deprecated-declarations)
