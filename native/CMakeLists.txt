cmake_minimum_required(VERSION 3.24)

# Preserve the old project's configurations: Release is intentionally /Od;
# Release_Final is the optimized shipping configuration.
if(CMAKE_HOST_WIN32)
	set(CMAKE_C_FLAGS_RELEASE "/Od /Ob0 /DNDEBUG /Zi" CACHE STRING "Release C flags")
	set(CMAKE_CXX_FLAGS_RELEASE "/Od /Ob0 /DNDEBUG /Zi" CACHE STRING "Release C++ flags")
	set(CMAKE_C_FLAGS_RELEASE_FINAL "/O2 /Ob2 /DNDEBUG /Zi" CACHE STRING "Shipping C flags")
	set(CMAKE_CXX_FLAGS_RELEASE_FINAL "/O2 /Ob2 /DNDEBUG /Zi" CACHE STRING "Shipping C++ flags")
endif()

project(mcswep_native_mesh LANGUAGES C CXX)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8 AND NOT CMAKE_SIZEOF_VOID_P EQUAL 4)
	message(FATAL_ERROR "MineMod Native requires an x86 or x64 toolchain.")
endif()

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(CMAKE_CONFIGURATION_TYPES)
	set(CMAKE_CONFIGURATION_TYPES "Debug;Release;Release_Final" CACHE STRING "Build configurations" FORCE)
elseif(NOT CMAKE_BUILD_TYPE)
	set(CMAKE_BUILD_TYPE Release_Final CACHE STRING "Build configuration" FORCE)
endif()

option(MCSWEP_BUILD_MODULE "Build the Windows GMod client module" ON)
option(MCSWEP_BUILD_TESTS "Build CPU tests and opt-in probes" OFF)
set(GMOD_BRANCH "auto" CACHE STRING "GMod engine branch: auto, public or x86-64")
set_property(CACHE GMOD_BRANCH PROPERTY STRINGS auto public x86-64)
if(NOT GMOD_BRANCH STREQUAL "auto" AND NOT GMOD_BRANCH STREQUAL "public" AND NOT GMOD_BRANCH STREQUAL "x86-64")
	message(FATAL_ERROR "GMOD_BRANCH must be auto, public or x86-64.")
endif()
if(NOT GMOD_BRANCH STREQUAL "public" AND NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
	message(FATAL_ERROR "Auto/beta builds require a 64-bit toolchain. Use GMOD_BRANCH=public for x86.")
endif()

include(cmake/NativeCore.cmake)

if(MCSWEP_BUILD_MODULE)
	if(NOT WIN32 OR NOT MSVC)
		message(FATAL_ERROR "The GMod module requires an MSVC Windows x86 or x64 toolchain.")
	endif()

	set(MCSWEP_SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/sdk")
	add_library(source_sdk INTERFACE)
	target_include_directories(source_sdk SYSTEM INTERFACE
		"${MCSWEP_SDK_ROOT}"
		"${MCSWEP_SDK_ROOT}/public"
		"${MCSWEP_SDK_ROOT}/public/tier0"
	)
	if(NOT GMOD_BRANCH STREQUAL "x86-64")
		target_compile_definitions(source_sdk INTERFACE GMOD_SDK_PUBLIC=1)
	else()
		target_compile_definitions(source_sdk INTERFACE GMOD_SDK_X86_64=1)
	endif()
	target_compile_definitions(source_sdk INTERFACE
		COMPILER_MSVC RAD_TELEMETRY_DISABLED GMOD_USE_SOURCESDK
	)
	if(CMAKE_SIZEOF_VOID_P EQUAL 8)
		target_compile_definitions(source_sdk INTERFACE COMPILER_MSVC64)
		target_link_libraries(source_sdk INTERFACE "${MCSWEP_SDK_ROOT}/lib/public/x64/tier0.lib")
		set(module_platform win64)
	else()
		target_compile_definitions(source_sdk INTERFACE COMPILER_MSVC32)
		target_link_libraries(source_sdk INTERFACE "${MCSWEP_SDK_ROOT}/lib/public/tier0.lib")
		set(module_platform win32)
	endif()

	add_library(mcswep_native_mesh MODULE
		Module/Module.cpp
		Module/Handshake.cpp
		Bindings/AtlasSpriteBindings.cpp
		Bindings/DrawBindings.cpp
		Bindings/LegacyMeshDrawBindings.cpp
		Bindings/MeshBindingContext.cpp
		Bindings/MeshBindings.cpp
		Bindings/MeshInputBindings.cpp
		Bindings/PixelTextureBindings.cpp
		Bindings/ResourceBindings.cpp
		Bindings/WorldBindings.cpp
		Render/Source/EngineContext.cpp
		Render/Source/MeshIndex.cpp
		Render/Source/MeshResource.cpp
		Render/Source/PublishedMesh.cpp
		Resources/Source/AtlasTexture.cpp
		Resources/Source/PixelTexture.cpp
		Resources/Source/PixelTextureStore.cpp
		Legacy/BlockDefinitions.cpp
		Legacy/BlockEmitters.cpp
		Legacy/ChunkMeshBuilder.cpp
		Legacy/ChunkMeshDraw.cpp
		Legacy/ChunkMeshWorker.cpp
		Legacy/DebugMesh.cpp
		Legacy/LightAtlas.cpp
		Legacy/PatchDecoder.cpp
		Legacy/WorldMirror.cpp
	)
	target_link_libraries(mcswep_native_mesh PRIVATE mc_native_core source_sdk)
	target_include_directories(mcswep_native_mesh PRIVATE
		"${CMAKE_CURRENT_SOURCE_DIR}"
		"${CMAKE_CURRENT_SOURCE_DIR}/include"
	)
	target_compile_definitions(mcswep_native_mesh PRIVATE MCSWEPNATIVEMESH_EXPORTS _WINDOWS _USRDLL)
	if(GMOD_BRANCH STREQUAL "auto")
		target_compile_definitions(mcswep_native_mesh PRIVATE MCSWEP_AUTO_BRANCH=1)
	endif()
	target_precompile_headers(mcswep_native_mesh PRIVATE Module/Pch.h)
	set_source_files_properties(Bindings/ResourceBindings.cpp Bindings/AtlasSpriteBindings.cpp
		PROPERTIES SKIP_PRECOMPILE_HEADERS ON)
	target_link_options(mcswep_native_mesh PRIVATE /SUBSYSTEM:WINDOWS /MANIFESTUAC:NO /DEBUG
		"$<$<NOT:$<CONFIG:Debug>>:/OPT:REF>"
		"$<$<NOT:$<CONFIG:Debug>>:/OPT:ICF>"
		"$<$<CONFIG:Release_Final>:/LTCG>"
	)
	set(MCSWEP_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bin" CACHE PATH "Module output directory")
	set_target_properties(mcswep_native_mesh PROPERTIES
		PREFIX ""
		OUTPUT_NAME "gmcl_mcswep_native_mesh_${module_platform}"
		RUNTIME_OUTPUT_DIRECTORY "${MCSWEP_OUTPUT_DIRECTORY}"
		LIBRARY_OUTPUT_DIRECTORY "${MCSWEP_OUTPUT_DIRECTORY}"
	)

	foreach(target mc_native_core mc_miniz mc_lzma mcswep_native_mesh)
		target_compile_options(${target} PRIVATE /W3 /sdl /utf-8
			"$<$<COMPILE_LANGUAGE:CXX>:/permissive->"
			"$<$<NOT:$<CONFIG:Debug>>:/Gy>"
			"$<$<NOT:$<CONFIG:Debug>>:/Oi>"
			"$<$<CONFIG:Release_Final>:/GL>"
		)
		target_compile_definitions(${target} PRIVATE _CRT_SECURE_NO_WARNINGS)
	endforeach()
endif()

if(MCSWEP_BUILD_TESTS)
	enable_testing()
	add_subdirectory(tests)
endif()
