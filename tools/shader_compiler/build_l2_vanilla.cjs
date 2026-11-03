// Offline candidate build and descriptor generation. No game deployment or activation.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const ROOT = path.resolve(__dirname, "../..");
const SOURCE = path.join(__dirname, "shadersrc/l2/vanilla");
const ADDON = path.join(ROOT, "addons/mc_shaderpack_vanilla");
const DESCRIPTOR = path.join(ADDON, "data_static/mc/shaderpacks/mc_vanilla.json");
const TOOLS = ["shadercompile.exe", "shadercompile_dll.dll", "filesystem_stdio.dll",
  "steam_api.dll", "tier0.dll", "vstdlib.dll", "fxc.exe", "dx_proxy.dll",
  "d3dx9_33.dll", "d3dcompiler_43.dll"];
const PROGRAMS = {
  sampling_vertex: ["sampling_vertex.fxc", "vs_3_0"],
  sampling: ["sampling_pixel.fxc", "ps_3_0"],
  vertex: ["surface_vertex.fxc", "vs_3_0"],
  opaque: ["surface_opaque.fxc", "ps_3_0"],
  cutout: ["surface_cutout.fxc", "ps_3_0"],
  translucent: ["surface_translucent.fxc", "ps_3_0"],
  dynamic_vertex: ["surface_dynamic_vertex.fxc", "vs_3_0"],
  dynamic_opaque: ["surface_dynamic_opaque.fxc", "ps_3_0"],
  dynamic_cutout: ["surface_dynamic_cutout.fxc", "ps_3_0"],
  dynamic_translucent: ["surface_dynamic_translucent.fxc", "ps_3_0"],
  dynamic_sprite_vertex: ["surface_dynamic_sprite_vertex.fxc", "vs_3_0"],
  dynamic_sprite: ["surface_dynamic_sprite.fxc", "ps_3_0"],
};
const DEFINES = ["/DTOTALSHADERCOMBOS=1", "/DCENTROIDMASK=0",
  "/DNUMDYNAMICCOMBOS=1", "/DFLAGS=0x0"];
const sha256 = bytes => crypto.createHash("sha256").update(bytes).digest("hex");

function fingerprint(entries) {
  const hash = crypto.createHash("sha256");
  const seen = new Set();
  for (const [name, bytes] of [...entries].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)) {
    if (seen.has(name)) throw new Error(`Duplicate build input: ${name}`);
    seen.add(name);
    hash.update(JSON.stringify([name, bytes.length]) + "\n");
    hash.update(bytes);
  }
  return hash.digest("hex");
}

function readSources(directory = SOURCE, prefix = "") {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const relative = prefix + entry.name;
    if (entry.isDirectory()) return readSources(path.join(directory, entry.name), relative + "/");
    if (!entry.isFile() || !/\.(fxc|fxh|json)$/.test(entry.name)) throw new Error(`Unexpected source: ${relative}`);
    return [[relative, fs.readFileSync(path.join(directory, entry.name))]];
  });
}

function compilerSources(entries) {
  const files = new Map(entries);
  const flat = name => name.replaceAll("/", "__");
  const names = new Set();
  return entries.map(([name, bytes]) => {
    const target = flat(name);
    if (names.has(target)) throw new Error(`Flattened source collision: ${target}`);
    names.add(target);
    if (/\.(fxc|fxh)$/.test(name)) {
      const source = bytes.toString("utf8").replace(/(^[ \t]*#include[ \t]+)"([^"]+)"/gm, (_, directive, include) => {
        const dependency = path.posix.normalize(path.posix.join(path.posix.dirname(name), include));
        if (!files.has(dependency) || !dependency.endsWith(".fxh")) throw new Error(`Missing/unsupported include: ${name}: ${include}`);
        return `${directive}"${flat(dependency)}"`;
      });
      bytes = Buffer.from(source);
    }
    return [target, bytes];
  });
}

function bindingHeader(contract) {
  if (!((contract.id === "mc:vanilla_quad_draft" && contract.revision === 1)
      || (contract.id === "mc:vanilla_quad_v2" && contract.revision === 2)) || contract.gpuReady !== false
      || contract.atlasSize !== 16384 || contract.lightmapSize !== 16 || contract.verticesPerQuad !== 4
      || contract.material !== "screenspace_general_8tex") throw new Error("Unsupported draft contract");
  const occupied = new Set();
  const symbols = new Set();
  function claim(symbol, stage, slot, count) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(symbol) || symbols.has(symbol)) throw new Error("Invalid/duplicate binding symbol");
    symbols.add(symbol);
    if (!Number.isInteger(slot) || slot < 0) throw new Error("Invalid binding slot");
    for (let i = slot; i < slot + count; i++) {
      const key = `${stage}/${i}`;
      if (occupied.has(key)) throw new Error(`Overlapping binding: ${key}`);
      occupied.add(key);
    }
  }
  const declarations = { vertex: [], pixel: [] };
  if (contract.constants.length !== 2 || contract.samplers.length !== 3) throw new Error("Incomplete draft bindings");
  for (const constant of contract.constants) {
    const vertex = constant.stage === "vertex";
    if ((!vertex && constant.stage !== "pixel")
        || constant.slot !== (vertex ? 4 : 0) || constant.type !== (vertex ? "float4x4" : "float4")
        || constant.registers !== (vertex ? 4 : 1)) throw new Error("Unsupported constant binding");
    claim(constant.symbol, constant.stage, constant.slot, constant.registers);
    declarations[constant.stage].push(`${constant.type} ${constant.symbol} : register(c${constant.slot});`);
  }
  for (const sampler of contract.samplers) {
    const slot = sampler.slot;
    if (slot > 2 || sampler.materialKey !== ["$basetexture", "$texture1", "$texture2"][slot]
        || sampler.filter !== ["point", "point", "linear"][slot]
        || sampler.encoding !== ["unorm", "raw_rgba8", "unorm"][slot]) throw new Error("Unsupported sampler binding");
    claim(sampler.symbol, "sampler", slot, 1);
    declarations.pixel.push(`sampler2D ${sampler.symbol} : register(s${slot});`);
  }
  return Buffer.from(["// Generated from adapter/quad_draft.json; not a public ABI.",
    "#ifndef MC_VANILLA_BINDINGS_INCLUDED", "#define MC_VANILLA_BINDINGS_INCLUDED",
    "#if MC_VERTEX_STAGE", ...declarations.vertex, "#else", ...declarations.pixel,
    "#endif", "#endif", ""].join("\n"));
}

function compileArgs(file, profile, output) {
  return [...DEFINES, `/T${profile}`, `/DSHADER_MODEL_${profile.toUpperCase()}=1`,
    "/nologo", `/Fo${output}`, file];
}

function filelistEntry(name, file, profile) {
  return ["**** generated by build_l2_vanilla.cjs ****", `#BEGIN ${name}`, file,
    "#DEFINES-D:", "#DEFINES-S:", "#SKIP:", "0", "#COMMAND:",
    "fxc.exe " + DEFINES.join(" "),
    compileArgs(file, profile, "shader.o").slice(DEFINES.length).join(" ") + ">output.txt 2>&1",
    "#END", "**** end ****"].join("\r\n");
}

function run(exe, args, cwd, log) {
  const result = spawnSync(exe, args, { cwd, encoding: "utf8", windowsHide: true, timeout: 180000 });
  fs.writeFileSync(log, (result.stdout || "") + (result.stderr || ""));
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Compiler exit ${result.status}; see ${log}`);
  return result.stdout;
}

function validateReport(report, profile, key = "", experimentalAnimation = false) {
  const vertex = profile === "vs_3_0";
  const sampling = key === "sampling" || key === "sampling_vertex";
  const dynamic = key.startsWith("dynamic_");
  const constants = sampling ? vertex ? [] : [0] : vertex ? [4, 5, 6, 7, 58, 59, 60] : dynamic ? [0, 1, 2, 3, 16, 17, 18] : [0, 2, 3, 16, 17, 18];
  const samplers = vertex ? [] : sampling ? ["0", "3", "4"] : key === "dynamic_sprite" ? ["0", "2"] : ["0", "1", "2"];
  const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  if (report.kind !== (vertex ? "vs" : "ps") || report.ver !== "3_0"
      || !equal(report.external_consts, constants)
      || !equal(Object.keys(report.samplers), samplers)
      || !equal(report.color_writes, vertex ? [] : [0]) || report.depth_write
      || !/^[0-9a-f]{64}$/.test(report.instructionHash)) throw new Error("Compiled shader binding mismatch");
  if (dynamic && (!Number.isInteger(report.instructionSlots) || report.instructionSlots < 1)) {
    throw new Error(`Vanilla ${key} has an invalid instruction count`);
  }
  if (!vertex && !equal(report.centroidTexcoords, sampling ? [] : dynamic ? [0, 1, 3] : [0, 1])) {
    throw new Error(`Vanilla ${key} centroid interpolation mismatch`);
  }
}

// SCell555/ShaderCompile also runs without the legacy SDK's ten-file toolchain.
// Keep each shader's content-addressed name and the same bytecode validation.
function compileModern(compiler, build, requests) {
  for (const type of ["vs", "ps"]) {
    const files = requests.filter(r => r.profile.startsWith(type)).map(r => {
      const file = r.name + ".fxc";
      fs.copyFileSync(path.join(build, r.file), path.join(build, file));
      return file;
    });
    if (files.length) run(compiler, ["-ver", "30", "-types", type, "-threads", "1", "-shaderpath", build, "-force", ...files],
      build, path.join(build, "compiler-" + type + ".log"));
  }
}

function immutableWrite(file, bytes) {
  if (fs.existsSync(file)) {
    if (!fs.readFileSync(file).equals(bytes)) throw new Error(`Build-name collision: ${file}`);
    return;
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes, { flag: "wx" });
}

function packDefinition(manifest) {
  const programs = {};
  if (manifest.programs.sampling) programs.sampling = {
    vertex: manifest.programs.sampling_vertex.name, vertexHash: manifest.programs.sampling_vertex.sha256,
    pixel: manifest.programs.sampling.name, pixelHash: manifest.programs.sampling.sha256,
  };
  const passes = {};
  for (const [name, stage] of Object.entries({
    opaque: "world_opaque", cutout: "world_cutout", translucent: "world_translucent",
  })) {
    programs[name] = {
      vertex: manifest.programs.vertex.name, vertexHash: manifest.programs.vertex.sha256,
      pixel: manifest.programs[name].name, pixelHash: manifest.programs[name].sha256,
    };
    passes[`terrain_${name}`] = { stage, program: name };
  }
  if (manifest.binding.id === "mc:vanilla_quad_v2") {
    for (const key of ["dynamic_opaque", "dynamic_cutout", "dynamic_translucent", "dynamic_sprite"]) {
      const vertex = key === "dynamic_sprite" ? "dynamic_sprite_vertex" : "dynamic_vertex";
      programs[key] = { vertex: manifest.programs[vertex].name, vertexHash: manifest.programs[vertex].sha256,
        pixel: manifest.programs[key].name, pixelHash: manifest.programs[key].sha256 };
    }
  }
  return {
    schema: 1, name: "Vanilla", build: manifest.build, abi: 1,
    layout: "mc:quad_corners_v1", adapter: manifest.binding.id,
    programs, resources: {}, passes,
    implements: { "mc:terrain": { contract: 1,
      passes: ["terrain_opaque", "terrain_cutout", "terrain_translucent"] } },
  };
}

function descriptorDocument(manifest) {
  return { schema: 1, kind: "pack", id: "mc:vanilla", definition: packDefinition(manifest) };
}

function validatePublishedBuild(manifest) {
  if (manifest.schema !== 1 || manifest.phase !== "offline_candidate" || manifest.gpuReady !== false
      || !/^[0-9a-f]{64}$/.test(manifest.build)) throw new Error("Invalid candidate manifest");
  bindingHeader(manifest.binding);
  for (const [key, [, profile]] of Object.entries(PROGRAMS)) {
    if (key.startsWith("dynamic_") && manifest.binding.id === "mc:vanilla_quad_draft") continue;
    const program = manifest.programs[key];
    const name = `mc_vanilla_${key}_${manifest.build.slice(0, 20)}_${profile === "vs_3_0" ? "vs30" : "ps30"}`;
    if (!program || program.name !== name || program.profile !== profile) throw new Error(`Invalid candidate program: ${key}`);
    const bytes = fs.readFileSync(path.join(ADDON, "shaders/fxc", name + ".vcs"));
    if (bytes.length === 0 || bytes.length !== program.bytes || sha256(bytes) !== program.sha256) {
      throw new Error(`Candidate VCS does not match manifest: ${name}`);
    }
  }
}

function publishDescriptor(manifest) {
  validatePublishedBuild(manifest);
  fs.mkdirSync(path.dirname(DESCRIPTOR), { recursive: true });
  const temporary = DESCRIPTOR + `.tmp-${process.pid}`;
  fs.writeFileSync(temporary, JSON.stringify(descriptorDocument(manifest), null, 2) + "\n", { flag: "wx" });
  fs.renameSync(temporary, DESCRIPTOR);
}

function main(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === "--stage-only") flags.stageOnly = true;
    else if (flag === "--experimental-gpu-animation") flags.experimentalAnimation = true;
    else if (["--toolchain", "--compiler", "--game", "--reference", "--reference-sources", "--python", "--descriptor-from"].includes(flag)
        && argv[i + 1] && !argv[i + 1].startsWith("--")) {
      flags[flag.slice(2)] = flag === "--python" ? argv[++i] : path.resolve(argv[++i]);
    } else throw new Error(`Unknown/incomplete option: ${flag}`);
  }
  if (flags["descriptor-from"]) {
    if (Object.keys(flags).length !== 1) throw new Error("--descriptor-from cannot be combined with compile options");
    publishDescriptor(JSON.parse(fs.readFileSync(flags["descriptor-from"], "utf8")));
    console.log(`Published JSON from verified existing VCS; no compilation or deployment\nDescriptor: ${DESCRIPTOR}`);
    return;
  }
  if (flags.reference && flags["reference-sources"]) {
    throw new Error("Use either --reference <repository> or --reference-sources <directory>, not both");
  }
  const referenceSources = flags["reference-sources"] || (flags.reference
    ? path.join(flags.reference, "tools/shader_compiler/shadersrc/mc_gpu_test") : null);
  if (referenceSources) {
    if (flags.compiler) throw new Error("Reference comparison currently requires the legacy compiler");
    for (const name of ["mc_vanilla_quad_vs30.fxc", "mc_vanilla_quad.fxh"]) {
      if (!fs.statSync(path.join(referenceSources, name)).isFile()) {
        throw new Error(`Missing reference shader: ${path.join(referenceSources, name)}`);
      }
    }
  }
  const toolchain = flags.toolchain || path.join(__dirname, "toolchain");
  const game = flags.game || "D:/steam/steamapps/common/GarrysMod/garrysmod";
  if (!fs.statSync(path.join(game, "gameinfo.txt")).isFile()) throw new Error("Missing gameinfo.txt");
  const entries = [...readSources(),
    ["../pbr/materials/animation.fxh", fs.readFileSync(path.join(SOURCE,"../pbr/materials/animation.fxh"))],
    ...(flags.compiler ? [["modern-compiler.exe",fs.readFileSync(flags.compiler)]]
    : TOOLS.map(name => [name, fs.readFileSync(path.join(toolchain, name))]))];
  const contract = JSON.parse(entries.find(([name]) => name === "adapter/quad_draft.json")[1]);
  entries.push(["adapter/bindings.fxh", bindingHeader(contract)]);
  const digest = fingerprint([...entries, ["builder", fs.readFileSync(__filename)],
    ["experimentalAnimation", Buffer.from(String(!!flags.experimentalAnimation))],
    ["validator", fs.readFileSync(path.join(__dirname, "check_l2_vcs.py"))],
    ["scanner", fs.readFileSync(path.join(__dirname, "vcs_scan.py"))],
    ["programs", Buffer.from(JSON.stringify(PROGRAMS))]]);
  const id = digest.slice(0, 20);
  const parent = path.join(__dirname, ".build/l2_vanilla");
  fs.mkdirSync(parent, { recursive: true });
  const build = fs.mkdtempSync(path.join(parent, id + "-"));
  // Valve's compile file cache uses flat names. Keep the authored tree modular.
  const staged = compilerSources(entries);
  for (const [name, bytes] of staged) {
    const file = path.join(build, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, bytes);
  }
  const names = Object.fromEntries(Object.entries(PROGRAMS).map(([key, [, profile]]) =>
    [key, `mc_vanilla_${key}_${id}_${profile === "vs_3_0" ? "vs30" : "ps30"}`]));
  fs.writeFileSync(path.join(build, "filelist.txt"), Object.entries(PROGRAMS).map(([key, [file, profile]]) =>
    filelistEntry(names[key], file, profile)).join("\r\n") + "\r\n");
  fs.writeFileSync(path.join(build, "uniquefilestocopy.txt"), staged.map(([name]) => name).join("\r\n") + "\r\n");
  fs.mkdirSync(path.join(build, "shaders/fxc"), { recursive: true });
  console.log(`Build ${digest}\nStaging: ${build}`);
  if (flags.stageOnly) return;
  const referencePrograms = {};
  // Optional read-only reference audit, not a build dependency or a GPU test.
  if (referenceSources) {
    for (const name of ["mc_vanilla_quad_vs30.fxc", "mc_vanilla_quad.fxh"]) {
      fs.copyFileSync(path.join(referenceSources, name), path.join(build, name));
      fs.appendFileSync(path.join(build, "uniquefilestocopy.txt"), name + "\r\n");
    }
    for (const [key, translucent] of [["cutout", 0], ["translucent", 1]]) {
      fs.writeFileSync(path.join(build, `reference_${key}.fxc`),
        `#define MC_VANILLA_TRANSLUCENT ${translucent}\n#include "mc_vanilla_quad.fxh"\n`);
      fs.appendFileSync(path.join(build, "uniquefilestocopy.txt"), `reference_${key}.fxc\r\n`);
    }
    for (const key of ["vertex", "cutout", "translucent"]) {
      const file = key === "vertex" ? "mc_vanilla_quad_vs30.fxc" : `reference_${key}.fxc`;
      referencePrograms[key] = `reference_${key}_${key === "vertex" ? "vs30" : "ps30"}`;
      fs.appendFileSync(path.join(build, "filelist.txt"),
        filelistEntry(referencePrograms[key], file, PROGRAMS[key][1]) + "\r\n");
    }
  }
  if (flags.compiler) {
    compileModern(flags.compiler,build,Object.entries(names).map(([key,name])=>
      ({name,file:PROGRAMS[key][0].replaceAll("/","__"),profile:PROGRAMS[key][1]})));
  } else run(path.join(build, "shadercompile.exe"), ["-nompi", "-allowdebug", "-threads", "1", "-game", game, "-shaderpath", build],
    build, path.join(build, "compiler.log"));
  const reports = JSON.parse(run(flags.python || "python", ["-B", path.join(__dirname, "check_l2_vcs.py"), "--sm3-budget",
    ...[...Object.values(names), ...Object.values(referencePrograms)].map(name =>
      path.join(build, "shaders/fxc", name + ".vcs"))], build, path.join(build, "bytecode-report.json")));
  for (const [key, name] of Object.entries(names)) validateReport(reports[name], PROGRAMS[key][1], key, flags.experimentalAnimation);
  if (referenceSources) {
    const evidence = {};
    for (const [key, name] of Object.entries(referencePrograms)) {
      if (reports[names[key]].instructionHash !== reports[name].instructionHash) {
        throw new Error(`Reference bytecode mismatch: ${key}; inspect VCS files in ${build}`);
      }
      evidence[key] = { instructionsEqual: true, instructionHash: reports[name].instructionHash };
    }
    fs.writeFileSync(path.join(build, "reference-check.json"), JSON.stringify(evidence, null, 2) + "\n");
    console.log("Reference vertex/cutout/translucent executable bytecode: identical");
  }
  const output = Object.entries(names).map(([key, name]) => {
    const bytes = fs.readFileSync(path.join(build, "shaders/fxc", name + ".vcs"));
    return { key, name, bytes };
  });
  const manifest = { schema: 1, phase: "offline_candidate", gpuReady: false, build: digest,
    experimentalGPUAnimation: !!flags.experimentalAnimation,
    maxPixelInstructionSlots: Math.max(...Object.values(reports).filter(r => r.kind === "ps").map(r => r.instructionSlots)),
    binding: contract, programs: Object.fromEntries(output.map(({ key, name, bytes }) =>
      [key, { name, sha256: sha256(bytes), bytes: bytes.length, profile: PROGRAMS[key][1],
        instructionHash: reports[name].instructionHash }])) };
  const json = Buffer.from(JSON.stringify(manifest, null, 2) + "\n");
  const files = [...output.map(({ name, bytes }) => [path.join(ADDON, "shaders/fxc", name + ".vcs"), bytes]),
    [path.join(ADDON, "builds", digest + ".json"), json]];
  // Check all collisions before publishing any candidate. The JSON pointer is last.
  for (const [file, bytes] of files) {
    if (fs.existsSync(file) && !fs.readFileSync(file).equals(bytes)) throw new Error(`Build-name collision: ${file}`);
  }
  for (const [file, bytes] of files) immutableWrite(file, bytes);
  publishDescriptor(manifest);
  console.log(`Published ${output.length} candidate shaders to ${ADDON}\nDescriptor: ${DESCRIPTOR}`);
}

module.exports = { ROOT, SOURCE, ADDON, DESCRIPTOR, PROGRAMS, fingerprint, bindingHeader,
  compileArgs, filelistEntry, validateReport, immutableWrite, compilerSources, packDefinition, compileModern,
  descriptorDocument, validatePublishedBuild };
if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.stack); process.exitCode = 1; }
}
