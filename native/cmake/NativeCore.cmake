# Shared by the module and the standalone CPU-test entry point.
set(MCSWEP_NATIVE_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
cmake_path(NORMAL_PATH MCSWEP_NATIVE_ROOT)

add_library(mc_miniz STATIC
	"${MCSWEP_NATIVE_ROOT}/include/miniz/miniz.c"
	"${MCSWEP_NATIVE_ROOT}/include/miniz/miniz_tinfl.c"
	"${MCSWEP_NATIVE_ROOT}/include/miniz/miniz_zip.c"
)
target_include_directories(mc_miniz SYSTEM PUBLIC "${MCSWEP_NATIVE_ROOT}/include")
target_compile_definitions(mc_miniz PUBLIC MINIZ_NO_STDIO MINIZ_NO_DEFLATE_APIS MINIZ_NO_ZLIB_COMPATIBLE_NAMES)

add_library(mc_lzma STATIC "${MCSWEP_NATIVE_ROOT}/include/lzma/LzmaDec.c")
target_include_directories(mc_lzma SYSTEM PUBLIC "${MCSWEP_NATIVE_ROOT}/include")

add_library(mc_native_core STATIC
	"${MCSWEP_NATIVE_ROOT}/Core/CpuWorkGate.cpp"
	"${MCSWEP_NATIVE_ROOT}/World/WorldDecoder.cpp"
	"${MCSWEP_NATIVE_ROOT}/World/WorldTransport.cpp"
	"${MCSWEP_NATIVE_ROOT}/World/WorldStore.cpp"
	"${MCSWEP_NATIVE_ROOT}/World/WorldSession.cpp"
	"${MCSWEP_NATIVE_ROOT}/World/LightWorker.cpp"
	"${MCSWEP_NATIVE_ROOT}/Mesh/SectionTasks.cpp"
	"${MCSWEP_NATIVE_ROOT}/Mesh/SectionGeometry.cpp"
	"${MCSWEP_NATIVE_ROOT}/Mesh/SectionWorker.cpp"
	"${MCSWEP_NATIVE_ROOT}/Mesh/FluidGeometry.cpp"
	"${MCSWEP_NATIVE_ROOT}/Mesh/ModelShapes.cpp"
	"${MCSWEP_NATIVE_ROOT}/Mesh/WorldMeshInput.cpp"
	"${MCSWEP_NATIVE_ROOT}/Render/Visibility/ChunkVisibilityQuery.cpp"
	"${MCSWEP_NATIVE_ROOT}/Render/Visibility/VisibilityGraph.cpp"
	"${MCSWEP_NATIVE_ROOT}/Render/Visibility/VisibilityQuery.cpp"
	"${MCSWEP_NATIVE_ROOT}/Render/Visibility/VisibilityWorker.cpp"
	"${MCSWEP_NATIVE_ROOT}/Resources/ResourceSource.cpp"
	"${MCSWEP_NATIVE_ROOT}/Resources/Atlas/AtlasPixels.cpp"
)
target_compile_features(mc_native_core PUBLIC cxx_std_17)
target_include_directories(mc_native_core PUBLIC "${MCSWEP_NATIVE_ROOT}")
target_include_directories(mc_native_core SYSTEM PUBLIC "${MCSWEP_NATIVE_ROOT}/include/rapidjson-master/include")
find_package(Threads REQUIRED)
target_link_libraries(mc_native_core PUBLIC Threads::Threads PRIVATE mc_miniz mc_lzma)
if(WIN32)
	target_sources(mc_native_core PRIVATE "${MCSWEP_NATIVE_ROOT}/Resources/Atlas/AtlasSprite.cpp")
	target_link_libraries(mc_native_core PRIVATE windowscodecs ole32)
endif()
set_target_properties(mc_native_core mc_miniz mc_lzma PROPERTIES POSITION_INDEPENDENT_CODE ON)

# These files used /fp:strict in the original DLL project. Do not apply it to
# the Source SDK/PCH or turn this migration into a change of numerical behavior.
set(strict_sources
	Resources/Atlas/AtlasPixels.cpp Resources/Atlas/AtlasSprite.cpp
	Mesh/SectionTasks.cpp Mesh/SectionGeometry.cpp Mesh/SectionWorker.cpp
	Mesh/FluidGeometry.cpp Mesh/ModelShapes.cpp Mesh/WorldMeshInput.cpp
	World/WorldStore.cpp
	Render/Visibility/ChunkVisibilityQuery.cpp Render/Visibility/VisibilityGraph.cpp
	Render/Visibility/VisibilityQuery.cpp Render/Visibility/VisibilityWorker.cpp
)
foreach(source IN LISTS strict_sources)
	if(MSVC)
		set_property(SOURCE "${MCSWEP_NATIVE_ROOT}/${source}" APPEND PROPERTY COMPILE_OPTIONS /fp:strict)
	else()
		set_property(SOURCE "${MCSWEP_NATIVE_ROOT}/${source}" APPEND PROPERTY COMPILE_OPTIONS -ffp-contract=off)
	endif()
endforeach()
