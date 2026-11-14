set(TARGET PD2Jukebox)
add_library(${TARGET} SHARED dllmain.cpp jb_audio_impl.cpp)
target_include_directories(${TARGET} PRIVATE .)
target_link_libraries(${TARGET} PUBLIC UE4SS)
