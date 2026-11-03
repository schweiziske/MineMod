// Build immutable SM3 programs and a data-only PBR pack; never deploy to a client.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { fingerprint, compilerSources, filelistEntry, immutableWrite, compileModern } = require("./build_l2_vanilla.cjs");
const { constantPNG, publishedResources: engineResources } = require("./build_engine_render_textures.cjs");
const ROOT = path.resolve(__dirname, "../..");
const ADDON = path.join(ROOT, "addons/mc_shaderpack_pbr");
const DESCRIPTOR = path.join(ADDON, "data_static/mc/shaderpacks/mc_pbr.json");
const SETTINGS = path.join(__dirname, "shadersrc/l2/pbr_assets/settings.json");
const TOOLS = ["shadercompile.exe", "shadercompile_dll.dll", "filesystem_stdio.dll",
  "steam_api.dll", "tier0.dll", "vstdlib.dll", "fxc.exe", "dx_proxy.dll", "d3dx9_33.dll", "d3dcompiler_43.dll"];
const PROGRAMS = { vertex: "vs_3_0", opaque: "ps_3_0", cutout: "ps_3_0", translucent: "ps_3_0",
  shadow_vertex: "vs_3_0", shadow: "ps_3_0", block_entity_vertex: "vs_3_0", block_entity: "ps_3_0",
  water_vertex: "vs_3_0", water: "ps_3_0", water_shadow: "ps_3_0", water_caustics: "ps_3_0", scene_depth_vertex: "vs_3_0", scene_depth: "ps_3_0",
  ssr_copy_vertex: "vs_3_0", ssr_copy: "ps_3_0", ssr_source: "ps_3_0", water_ssr: "ps_3_0", water_ssr_composite: "ps_3_0", block_ssr: "ps_3_0",
  dynamic_opaque: "ps_3_0", dynamic_cutout: "ps_3_0", dynamic_translucent: "ps_3_0",
  dynamic_block_entity: "ps_3_0", dynamic_water: "ps_3_0", dynamic_sprite_vertex: "vs_3_0", dynamic_sprite: "ps_3_0",
  post_ssao: "ps_3_0", post_ssao_composite: "ps_3_0", post_scene_depth: "ps_3_0", post_depth_copy: "ps_3_0", post_fog: "ps_3_0",
  post_bloom_prefilter: "ps_3_0", post_bloom_blur: "ps_3_0", post_bloom_composite: "ps_3_0",
  post_volumetric: "ps_3_0", post_volumetric_composite: "ps_3_0",
  post_exposure_meter: "ps_3_0", post_exposure_reduce: "ps_3_0",
  post_exposure_adapt: "ps_3_0", post_exposure_composite: "ps_3_0", post_taa: "ps_3_0" };
const NO_SKY_PROGRAMS = ["opaque", "cutout", "translucent", "block_entity", "water",
  "shadow", "water_caustics", "post_volumetric"];
for (const key of NO_SKY_PROGRAMS) PROGRAMS[key + "_no_sky"] = "ps_3_0";
const sha256 = data => crypto.createHash("sha256").update(data).digest("hex");

function readTree(directory, prefix) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const name = prefix + entry.name, file = path.join(directory, entry.name);
    if (entry.isDirectory()) return readTree(file, name + "/");
    if (!entry.isFile() || !/\.(fxc|fxh|json)$/.test(name)) throw new Error(`Unexpected shader input: ${name}`);
    return [[name, fs.readFileSync(file)]];
  });
}

function validateReport(report, key, experimentalAnimation = false) {
  const noSky = key.endsWith("_no_sky");
  if (noSky) key = key.slice(0, -7);
  const vertex = key === "vertex" || key.endsWith("_vertex");
  const depth = key === "shadow";
  const water = key === "water";
  const extra = {
    water_shadow: { constants: [0, 1], samplers: [] },
    water_caustics: { constants: [0, 1, 11, 12, 13, 15, 16, 17], samplers: ["0", "1"] },
    scene_depth_vertex: { constants: [4, 5, 6, 7], samplers: [] },
    scene_depth: { constants: [0], samplers: ["0"] },
    ssr_copy_vertex: { constants: [], samplers: [] },
    ssr_copy: { constants: [], samplers: ["0"] },
    ssr_source: { constants: [0], samplers: ["0", "1"] },
    water_ssr: { constants: [0, 1, 2, 3, 11, 12, 13, 14, 15, 16], samplers: ["1", "3"] },
    water_ssr_composite: { constants: [1, 3, 4, 11, 12, 13, 15, 16, 17, 18], samplers: ["0", "1", "2", "3", "4", "6", "7"] },
    block_ssr: { constants: [0, 1, 2, 3, 11, 12, 13, 14, 15], samplers: ["0", "1", "2", "3", "4", "7"] },
    dynamic_opaque: { constants: [0, 1], samplers: ["0", "1", "2", "3", "4", "7"] },
    dynamic_cutout: { constants: [0, 1], samplers: ["0", "1", "2", "3", "4", "7"] },
    dynamic_translucent: { constants: [0, 1], samplers: ["0", "1", "2", "3", "4", "7"] },
    dynamic_block_entity: { constants: [0, 1], samplers: ["0", "2", "3", "4", "7"] },
    dynamic_water: { constants: [0, 1, 15, 16, 17, 18], samplers: ["2", "3"] },
    dynamic_sprite: { constants: [0, 1], samplers: ["0", "2"] },
    post_ssao: { constants: [0, 1, 2, 3], samplers: ["0"] },
    post_ssao_composite: { constants: [0, 1, 2], samplers: ["0", "1", "2"] },
    post_scene_depth: { constants: [0], samplers: ["0"] },
    post_depth_copy: { constants: [], samplers: ["0"] },
    post_fog: { constants: [0, 1, 2, 3, 11, 12, 13, 14], samplers: ["0", "1"] },
    post_bloom_prefilter: { constants: [0], samplers: ["0"] },
    post_bloom_blur: { constants: [0], samplers: ["0"] },
    post_bloom_composite: { constants: [0], samplers: ["0", "1"] },
    post_volumetric: { constants: [0, 1, 2, 3, 11, 12, 13, 14, 15, 16, 17, 18], samplers: ["0", "1"] },
    post_volumetric_composite: { constants: [0, 1], samplers: ["0", "1", "2"] },
    post_exposure_meter: { constants: [], samplers: ["0"] },
    post_exposure_reduce: { constants: [0], samplers: ["0"] },
    post_exposure_adapt: { constants: [0, 1], samplers: ["0", "1"] },
    post_exposure_composite: { constants: [], samplers: ["0", "1"] },
    post_taa: { constants: [0, 1, 2, 11, 12, 13, 15, 16, 17], samplers: ["0", "1", "2"] },
  }[key];
  if (extra && ["scene_depth", "post_scene_depth", "block_ssr", "dynamic_opaque", "dynamic_cutout",
    "dynamic_translucent", "dynamic_block_entity", "dynamic_sprite"].includes(key)) extra.constants.push(16,17,18);
  const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  if (!report || report.ver !== "3_0" || report.kind !== (vertex ? "vs" : "ps")
      || !equal(report.external_consts, extra ? extra.constants : vertex ? [4, 5, 6, 7, 58, 59, 60] : depth ? (noSky ? [0, 1, 16, 17, 18] : [0, 1, 2, 16, 17, 18])
        : water ? [0, 1, 2, 3, 4, 11, 12, 13, 14, 15, 16, 17, 18] : [0, 1, 2, 3, 11, 12, 13, 14, 16, 17, 18])
      || !equal(Object.keys(report.samplers), extra ? extra.samplers : vertex ? [] : depth ? (noSky ? ["0"] : ["0", "1"]) : water ? ["0", "1", "2", "3", "5", "6"]
        : key === "block_entity" ? ["0", "2", "3", "4", "5", "6", "7"] : ["0", "1", "2", "3", "4", "5", "6", "7"])
      || !equal(report.color_writes, vertex ? [] : [0]) || report.depth_write) {
    throw new Error(`PBR bytecode binding mismatch: ${JSON.stringify(report)}`);
  }
  if (!Number.isInteger(report.instructionSlots) || report.instructionSlots < 1) {
    throw new Error(`PBR ${key} has an invalid instruction count: ${report.instructionSlots}`);
  }
}

function run(exe, args, cwd, log) {
  // A full 34-program compile can exceed three minutes on slower machines.
  const result = spawnSync(exe, args, { cwd, encoding: "utf8", windowsHide: true, timeout: 900000 });
  fs.writeFileSync(log, (result.stdout || "") + (result.stderr || ""));
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Command exit ${result.status}; see ${log}`);
  return result.stdout;
}

function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = file + `.tmp-${process.pid}`;
  fs.writeFileSync(temporary, bytes, { flag: "wx" });
  try { fs.renameSync(temporary, file); }
  catch (error) { fs.unlinkSync(temporary); throw error; }
}

function publishedResources() {
  const { resources } = engineResources();
  const previous = JSON.parse(fs.readFileSync(DESCRIPTOR, "utf8")).definition.resources;
  // Shader support stays in this addon. Surface maps belong to texture packs.
  for (const name of ["environment", "dfg", "water_normal"]) {
    const resource = previous[name];
    if (!resource || !/^materials\/mc_pbr\/[a-z0-9_]+\.png$/.test(resource.path)
        || sha256(fs.readFileSync(path.join(ADDON, resource.path))) !== resource.sha256)
      throw new Error(`Invalid PBR support resource: ${name}`);
    resources[name] = resource;
  }
  return { resources, bytes: Buffer.from(JSON.stringify(resources)) };
}

function stampDefinition(definition) {
  // Descriptor identity also covers settings; GPU names keep their build hash.
  delete definition.build;
  definition.build = sha256(Buffer.from(JSON.stringify(definition)));
}

function publishEngineResources() {
  const descriptor = JSON.parse(fs.readFileSync(DESCRIPTOR, "utf8"));
  const { resources } = publishedResources();
  const definition = descriptor.definition;
  definition.resources = resources;
  definition.materialMaps = {};
  // Resource-only publication does not recompile or rename unchanged bytecode.
  stampDefinition(definition);
  atomicWrite(DESCRIPTOR, JSON.stringify(descriptor, null, 2).replace(/\n/g, "\r\n") + "\r\n");
  console.log(`Published texture-pack-driven PBR descriptor: ${definition.build}`);
}

function publishSettings() {
  const descriptor = JSON.parse(fs.readFileSync(DESCRIPTOR, "utf8"));
  const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
  Object.assign(descriptor.definition, { settingGroups: settings.groups, settings: settings.settings,
    presets: settings.presets, defaultPreset: settings.defaultPreset });
  // Settings participate in registry identity, not the immutable GPU build.
  stampDefinition(descriptor.definition);
  atomicWrite(DESCRIPTOR, JSON.stringify(descriptor, null, 2).replace(/\n/g, "\r\n") + "\r\n");
  console.log("Published PBR settings; shader programs and pipeline unchanged");
}

// Delete .vcs files of earlier builds; the new descriptor must already be published.
function pruneOldShaders() {
  const { programs } = JSON.parse(fs.readFileSync(DESCRIPTOR, "utf8")).definition;
  const keep = new Set(Object.values(programs).flatMap(p => [p.vertex + ".vcs", p.pixel + ".vcs"]));
  const directory = path.join(ADDON, "shaders/fxc");
  const old = fs.readdirSync(directory).filter(name => name.startsWith("mc_pbr_") && !keep.has(name));
  for (const name of old) fs.unlinkSync(path.join(directory, name));
  console.log(`Removed ${old.length} old shader files`);
}

function main(argv) {
  if (argv.length === 1 && argv[0] === "--resources-only") return publishEngineResources();
  if (argv.length === 1 && argv[0] === "--settings-only") return publishSettings();
  const options = { toolchain: path.join(__dirname, "toolchain"),
    game: "D:/steam/steamapps/common/GarrysMod/garrysmod", python: "python" };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === "--stage-only") options.stageOnly = true;
    else if (flag === "--experimental-gpu-animation") options.experimentalAnimation = true;
    else if (flag === "--reuse-resources") { /* Engine resources are always reused. */ }
    else if (["--toolchain", "--compiler", "--game", "--python"].includes(flag) && argv[i + 1]) options[flag.slice(2)] = argv[++i];
    else throw new Error(`Unknown/incomplete option ${flag}`);
  }
  if (!fs.statSync(path.join(options.game, "gameinfo.txt")).isFile()) throw new Error("Missing gameinfo.txt");
  const published = publishedResources();
  const generatorInputs = [["engineResources", published.bytes]];
  const sources = [...readTree(path.join(__dirname, "shadersrc/l2/pbr"), "pbr/"),
    ...["lighting/corner_atlas.fxh", "lighting/tint.fxh", "lighting/water_fog.fxh", "lighting/dynamic_lights.fxh", "dynamic/interface.fxh", "dynamic/vertex.fxh", "dynamic/surface.fxh", "materials/atlas.fxh", "materials/animation.fxh"]
      .map(name => ["vanilla/" + name, fs.readFileSync(path.join(__dirname, "shadersrc/l2/vanilla", name))])];
  const contract = JSON.parse(sources.find(([name]) => name === "pbr/adapter/quad_pbr.json")[1]);
  const notices = [
    ["third_party/filament/LICENSE", fs.readFileSync(path.join(ROOT, "third_party/filament/LICENSE"))],
    ["third_party/filament/NOTICE.md", fs.readFileSync(path.join(ROOT, "third_party/filament/NOTICE.md"))],
    ["third_party/complementary/NOTICE.md", fs.readFileSync(path.join(ROOT, "third_party/complementary/NOTICE.md"))],
    ["third_party/threejs/LICENSE", fs.readFileSync(path.join(ROOT, "third_party/threejs/LICENSE"))],
    ["third_party/threejs/NOTICE.md", fs.readFileSync(path.join(ROOT, "third_party/threejs/NOTICE.md"))],
    ["third_party/polyhaven/environment.json", fs.readFileSync(path.join(__dirname, "shadersrc/l2/pbr_assets/environment.json"))]
  ];
  const entries = [...sources, ...(options.compiler ? [["modern-compiler.exe",fs.readFileSync(options.compiler)]]
    : TOOLS.map(name => [name, fs.readFileSync(path.join(options.toolchain, name))]))];
  const digest = fingerprint([...entries, ...notices, ["builder", fs.readFileSync(__filename)],
    ["experimentalAnimation", Buffer.from(String(!!options.experimentalAnimation))],
    ...generatorInputs,
    ["builderHelpers", fs.readFileSync(path.join(__dirname, "build_l2_vanilla.cjs"))],
    ["validator", fs.readFileSync(path.join(__dirname, "check_l2_vcs.py"))],
    ["scanner", fs.readFileSync(path.join(__dirname, "vcs_scan.py"))]]);
  const parent = path.join(__dirname, ".build/l2_pbr");
  fs.mkdirSync(parent, { recursive: true });
  const build = fs.mkdtempSync(path.join(parent, digest.slice(0, 20) + "-"));
  const staged = compilerSources(entries);
  for (const key of NO_SKY_PROGRAMS) staged.push([`pbr__surface_${key}_no_sky.fxc`,
    Buffer.from(`#define MC_SKY_BOUNDARY 0\n#include "pbr__surface_${key}.fxc"\n`)]);
  for (const [name, bytes] of staged) fs.writeFileSync(path.join(build, name), bytes);
  const names = Object.fromEntries(Object.entries(PROGRAMS).map(([key, profile]) =>
    [key, `mc_pbr_${key}_${digest.slice(0, 20)}_${profile === "vs_3_0" ? "vs30" : "ps30"}`]));
  fs.writeFileSync(path.join(build, "filelist.txt"), Object.entries(PROGRAMS).map(([key, profile]) =>
    filelistEntry(names[key], `pbr__surface_${key}.fxc`, profile)).join("\r\n") + "\r\n");
  fs.writeFileSync(path.join(build, "uniquefilestocopy.txt"), staged.map(([name]) => name).join("\r\n") + "\r\n");
  fs.mkdirSync(path.join(build, "shaders/fxc"), { recursive: true });
  console.log(`PBR build ${digest}\nStaging: ${build}`);
  if (options.stageOnly) return;
  if (options.compiler) compileModern(options.compiler,build,Object.entries(names).map(([key,name])=>
    ({name,file:`pbr__surface_${key}.fxc`,profile:PROGRAMS[key]})));
  else run(path.join(build, "shadercompile.exe"), ["-nompi", "-allowdebug", "-threads", "1", "-game", options.game, "-shaderpath", build],
    build, path.join(build, "compiler.log"));
  const reports = JSON.parse(run(options.python, ["-B", path.join(__dirname, "check_l2_vcs.py"), "--sm3-budget",
    ...Object.values(names).map(name => path.join(build, "shaders/fxc", name + ".vcs"))],
    build, path.join(build, "bytecode-report.json")));
  for (const [key, name] of Object.entries(names)) validateReport(reports[name], key, options.experimentalAnimation);
  const output = Object.entries(names).map(([key, name]) => ({ key, name,
    bytes: fs.readFileSync(path.join(build, "shaders/fxc", name + ".vcs")) }));
  const manifest = { schema: 1, phase: "offline_candidate", gpuReady: false, build: digest, binding: contract,
    experimentalGPUAnimation: !!options.experimentalAnimation,
    maxPixelInstructionSlots: Math.max(...Object.values(reports).filter(r => r.kind === "ps").map(r => r.instructionSlots)),
    notices: notices.map(([name, bytes]) => ({ path: name, sha256: sha256(bytes) })),
    programs: Object.fromEntries(output.map(({ key, name, bytes }) => [key, {
      name, sha256: sha256(bytes), bytes: bytes.length, profile: PROGRAMS[key],
      instructionHash: reports[name].instructionHash }])) };
  const resources = published.resources;
  const materialMaps = {};
  // Player-adjustable settings live outside the shader tree, so editing them
  // never renames the compiled programs. The client validates the schema.
  const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
  const definition = { schema: 1, name: "PBR", build: digest, abi: 1,
    layout: "mc:quad_corners_v1", adapter: contract.id, programs: {}, resources, passes: {},
    materialMaps, settingGroups: settings.groups, settings: settings.settings,
    presets: settings.presets, defaultPreset: settings.defaultPreset,
    implements: { "mc:terrain": { contract: 1, passes: ["terrain_opaque", "terrain_cutout", "terrain_translucent"] } } };
  for (const key of ["opaque", "cutout", "translucent"]) {
    definition.programs[key] = { vertex: names.vertex, vertexHash: manifest.programs.vertex.sha256,
      pixel: names[key], pixelHash: manifest.programs[key].sha256 };
    definition.passes[`terrain_${key}`] = { stage: "world_" + key, program: key,
      inputs: { normal: "normal", orm: "orm", environment: "environment", dfg: "dfg" } };
  }
  definition.programs.shadow = { vertex: names.shadow_vertex, vertexHash: manifest.programs.shadow_vertex.sha256,
    pixel: names.shadow, pixelHash: manifest.programs.shadow.sha256 };
  definition.programs.block_entity = { vertex: names.block_entity_vertex, vertexHash: manifest.programs.block_entity_vertex.sha256,
    pixel: names.block_entity, pixelHash: manifest.programs.block_entity.sha256 };
  definition.programs.water = { vertex: names.water_vertex, vertexHash: manifest.programs.water_vertex.sha256,
    pixel: names.water, pixelHash: manifest.programs.water.sha256 };
  definition.programs.water_shadow = { vertex: names.shadow_vertex, vertexHash: manifest.programs.shadow_vertex.sha256,
    pixel: names.water_shadow, pixelHash: manifest.programs.water_shadow.sha256 };
  definition.programs.water_caustics = { vertex: names.ssr_copy_vertex, vertexHash: manifest.programs.ssr_copy_vertex.sha256,
    pixel: names.water_caustics, pixelHash: manifest.programs.water_caustics.sha256 };
  const normalBytes = fs.readFileSync(path.join(ADDON, resources.water_normal.path));
  if (normalBytes.length < 24 || normalBytes.subarray(1, 4).toString() !== "PNG"
      || normalBytes.readUInt32BE(16) !== normalBytes.readUInt32BE(20))
    throw new Error("Water refraction requires the square water-normal PNG");
  const normalSize = normalBytes.readUInt32BE(16);
  definition.pipeline = { version: 2,
    geometry: ["water_reflections", "water_depth", "terrain_reflections"],
    targets: { sunlight: { size: { relative: "shadow", scale: 1 }, format: "rgba8", filter: "point", clear: [1, 1, 1, 1] } },
    passes: [{ id: "water_light", stage: "shadowcomp", program: "water_caustics",
      inputs: { s0: { builtin: "shadow_atlas" }, s1: { resource: "water_normal", repeatTexture: true, filter: "linear" } },
      output: "sunlight", constants: { c0: ["time", "setting:water_waves", "shadow_resolution", normalSize],
        c1: ["sun_x", "sun_y", "sun_z", 0] },
      matrices: { viewproj: "shadow_near_world", invviewproj: "shadow_far_world" }, worldPeriod: 4096,
      enableSettings: ["water", "water_waves", "water_caustics"], disabledInput: "s0" }],
    exports: { shadow_atlas: "sunlight" } };
  for (const key of ["scene_depth", "ssr_copy", "ssr_source", "water_ssr", "water_ssr_composite"]) {
    const vertex = key.startsWith("water_") ? "water_vertex" : key === "ssr_source" ? "ssr_copy_vertex" : key + "_vertex";
    definition.programs[key] = { vertex: names[vertex], vertexHash: manifest.programs[vertex].sha256,
      pixel: names[key], pixelHash: manifest.programs[key].sha256 };
  }
  definition.programs.block_ssr = { vertex: names.vertex, vertexHash: manifest.programs.vertex.sha256,
    pixel: names.block_ssr, pixelHash: manifest.programs.block_ssr.sha256 };
  for (const key of ["dynamic_opaque", "dynamic_cutout", "dynamic_translucent", "dynamic_block_entity", "dynamic_water", "dynamic_sprite"]) {
    const vertex = key === "dynamic_water" ? "water_vertex" : key === "dynamic_block_entity" ? "block_entity_vertex"
      : key === "dynamic_sprite" ? "dynamic_sprite_vertex" : "vertex";
    definition.programs[key] = { vertex: names[vertex], vertexHash: manifest.programs[vertex].sha256,
      pixel: names[key], pixelHash: manifest.programs[key].sha256 };
  }
  for (const key of ["post_ssao", "post_ssao_composite", "post_scene_depth", "post_depth_copy", "post_fog",
    "post_bloom_prefilter", "post_bloom_blur", "post_bloom_composite", "post_volumetric", "post_volumetric_composite",
    "post_exposure_meter", "post_exposure_reduce", "post_exposure_adapt", "post_exposure_composite", "post_taa"]) {
    const vertex = key === "post_scene_depth" ? "scene_depth_vertex" : "ssr_copy_vertex";
    definition.programs[key] = { vertex: names[vertex], vertexHash: manifest.programs[vertex].sha256,
      pixel: names[key], pixelHash: manifest.programs[key].sha256 };
  }
  for (const key of NO_SKY_PROGRAMS) {
    definition.programs[key + "_no_sky"] = { ...definition.programs[key],
      pixel: names[key + "_no_sky"], pixelHash: manifest.programs[key + "_no_sky"].sha256 };
  }
  const target = (scale, maxWidth, maxHeight, filter = "point") => ({
    size: { relative: "view", scale, maxWidth, maxHeight }, format: "rgba16f", filter, clear: [0, 0, 0, 0] });
  Object.assign(definition.pipeline.targets, {
    ao: target(0.5, 960, 540), volume: target(0.5, 960, 540),
    bloom_a: target(0.25, 640, 360, "linear"), bloom_b: target(0.25, 640, 360, "linear"),
    taa_current: target(1), taa_history: target(1, undefined, undefined, "linear")
  });
  for (const [name, size] of Object.entries({ exposure_tiles: 64, exposure_16: 16, exposure_4: 4,
    exposure_current: 1, exposure_history: 1 })) {
    definition.pipeline.targets[name] = { size: { width: size, height: size },
      format: "rgba16f", filter: "point", clear: [0, 0, 0, 0] };
  }
  const builtin = name => ({ builtin: name });
  const targetInput = name => ({ target: name });
  const screenPass = (id, stage, program, inputs, targetName) => ({
    id, stage, program, inputs, output: targetName, binding: id });
  definition.pipeline.passes.push(
    screenPass("ssao", "opaque", "post_ssao", { s0: builtin("opaque_depth") }, "ao"),
    screenPass("ssao_composite", "opaque", "post_ssao_composite", {
      s0: builtin("scene_color"), s1: targetInput("ao"), s2: builtin("opaque_depth") }, "screen"),
    screenPass("fog", "world", "post_fog", { s0: builtin("scene_color"), s1: builtin("scene_depth") }, "screen"),
    screenPass("volumetric", "world", "post_volumetric", {
      s0: builtin("scene_depth"), s1: builtin("volume_shadow") }, "volume"),
    screenPass("volumetric_composite", "world", "post_volumetric_composite", {
      s0: builtin("scene_color"), s1: targetInput("volume"), s2: builtin("scene_depth") }, "screen"),
    screenPass("taa_resolve", "world", "post_taa", {
      s0: builtin("scene_color"), s1: builtin("scene_depth"), s2: builtin("taa_history") }, "taa_current"),
    screenPass("taa_composite", "world", "ssr_copy", { s0: targetInput("taa_current") }, "screen"),
    screenPass("taa_store", "world", "ssr_copy", { s0: targetInput("taa_current") }, "taa_history"),
    screenPass("exposure_meter", "final", "post_exposure_meter", { s0: builtin("scene_color") }, "exposure_tiles"),
    screenPass("exposure_reduce_16", "final", "post_exposure_reduce", { s0: targetInput("exposure_tiles") }, "exposure_16"),
    screenPass("exposure_reduce_4", "final", "post_exposure_reduce", { s0: targetInput("exposure_16") }, "exposure_4"),
    screenPass("exposure_adapt", "final", "post_exposure_adapt", {
      s0: targetInput("exposure_4"), s1: builtin("exposure_history") }, "exposure_current"),
    screenPass("exposure_composite", "final", "post_exposure_composite", {
      s0: builtin("scene_color"), s1: targetInput("exposure_current") }, "screen"),
    screenPass("bloom_prefilter", "final", "post_bloom_prefilter", { s0: builtin("scene_color") }, "bloom_a"),
    screenPass("bloom_horizontal", "final", "post_bloom_blur", { s0: targetInput("bloom_a") }, "bloom_b"),
    screenPass("bloom_vertical", "final", "post_bloom_blur", { s0: targetInput("bloom_b") }, "bloom_a"),
    screenPass("bloom_composite", "final", "post_bloom_composite", {
      s0: builtin("scene_color"), s1: targetInput("bloom_a") }, "screen"),
    screenPass("exposure_store", "final", "ssr_copy", { s0: targetInput("exposure_current") }, "exposure_history")
  );
  const files = [...output.map(({ name, bytes }) => [path.join(ADDON, "shaders/fxc", name + ".vcs"), bytes]),
    [path.join(ADDON, "builds", digest + ".json"), Buffer.from(JSON.stringify(manifest, null, 2) + "\n")]];
  for (const [file, bytes] of files) {
    if (fs.existsSync(file) && !fs.readFileSync(file).equals(bytes)) throw new Error(`Build-name collision: ${file}`);
  }
  for (const [file, bytes] of files) immutableWrite(file, bytes);
  for (const [name, bytes] of notices) atomicWrite(path.join(ADDON, name), bytes);
  stampDefinition(definition);
  atomicWrite(DESCRIPTOR, JSON.stringify({ schema: 1, kind: "pack", id: "mc:pbr", definition }, null, 2).replace(/\n/g, "\r\n") + "\r\n");
  console.log(`Published ${output.length} validated SM3 programs and data maps\nDescriptor: ${DESCRIPTOR}`);
  pruneOldShaders();
}

module.exports = { constantPNG, validateReport };
if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.stack); process.exitCode = 1; }
}
