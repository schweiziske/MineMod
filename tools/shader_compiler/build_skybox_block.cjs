// Offline sky material build. Publishes only into the repository addon.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { ROOT, fingerprint, filelistEntry, immutableWrite } = require("./build_l2_vanilla.cjs");
const ADDON = path.join(ROOT, "addons/mc_skybox_block");
const DESCRIPTOR = path.join(ADDON, "data_static/mc/shaderpacks/mc_skybox_captured.json");
const PROGRAMS = { vertex: ["sky_vertex.fxc", "vs_3_0"], surface: ["sky_surface.fxc", "ps_3_0"] };
const TOOLS = ["shadercompile.exe", "shadercompile_dll.dll", "filesystem_stdio.dll",
  "steam_api.dll", "tier0.dll", "vstdlib.dll", "fxc.exe", "dx_proxy.dll",
  "d3dx9_33.dll", "d3dcompiler_43.dll"];
const sha256 = bytes => crypto.createHash("sha256").update(bytes).digest("hex");

function validateReport(report, vertex) {
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  if (report.kind !== (vertex ? "vs" : "ps") || report.ver !== "3_0"
      || !same(report.external_consts, vertex ? [4, 5, 6, 7] : [0])
      || !same(Object.keys(report.samplers), vertex ? [] : ["0"])
      || !same(report.color_writes, vertex ? [] : [0]) || report.depth_write
      || !Number.isInteger(report.instructionSlots) || report.instructionSlots < 1
      || report.instructionSlots > 512 || !/^[0-9a-f]{64}$/.test(report.instructionHash)) {
    throw new Error("Sky shader bytecode does not match the sky-quad-v1 contract");
  }
}

function descriptorDocument(manifest) {
  const { vertex, surface } = manifest.programs;
  return { schema: 1, kind: "shader", id: "mc_skybox:captured", definition: {
    schema: 1, name: "Captured Source Sky", build: manifest.build,
    abi: 1, layout: "mc:quad_corners_v1", adapter: "mc:sky_quad_v1",
    programs: { sky: { vertex: vertex.name, pixel: surface.name,
      vertexHash: vertex.sha256, pixelHash: surface.sha256 } },
    resources: {}, passes: { sky: { stage: "world_opaque", program: "sky" } },
    implements: { "mc_skybox:sky": { contract: 1, passes: ["sky"] } },
  } };
}

function run(exe, args, cwd, log) {
  const result = spawnSync(exe, args, { cwd, encoding: "utf8", windowsHide: true, timeout: 180000 });
  fs.writeFileSync(log, (result.stdout || "") + (result.stderr || ""));
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Exit ${result.status}: ${log}`);
  return result.stdout;
}

function main(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (!["--toolchain", "--game", "--python"].includes(flag) || !argv[i + 1]
        || argv[i + 1].startsWith("--")) throw new Error(`Unknown/incomplete option: ${flag}`);
    flags[flag.slice(2)] = argv[++i];
  }
  const toolchain = path.resolve(flags.toolchain || path.join(__dirname, "toolchain"));
  const game = path.resolve(flags.game || "D:/steam/steamapps/common/GarrysMod/garrysmod");
  if (!fs.statSync(path.join(game, "gameinfo.txt")).isFile()) throw new Error("Missing gameinfo.txt");
  const entries = [
    ...Object.values(PROGRAMS).map(([name]) => [name, fs.readFileSync(path.join(ADDON, "shadersrc", name))]),
    ...TOOLS.map(name => [name, fs.readFileSync(path.join(toolchain, name))]),
  ];
  const build = fingerprint([...entries, ["builder", fs.readFileSync(__filename)],
    ["helper", fs.readFileSync(path.join(__dirname, "build_l2_vanilla.cjs"))],
    ["validator", fs.readFileSync(path.join(__dirname, "check_l2_vcs.py"))],
    ["scanner", fs.readFileSync(path.join(__dirname, "vcs_scan.py"))]]);
  const parent = path.join(__dirname, ".build/skybox_block");
  fs.mkdirSync(parent, { recursive: true });
  const stage = fs.mkdtempSync(path.join(parent, build.slice(0, 20) + "-"));
  for (const [name, bytes] of entries) fs.writeFileSync(path.join(stage, name), bytes);
  const names = Object.fromEntries(Object.entries(PROGRAMS).map(([key, [, profile]]) =>
    [key, `mc_sky_${key}_${build.slice(0, 20)}_${profile === "vs_3_0" ? "vs30" : "ps30"}`]));
  fs.writeFileSync(path.join(stage, "filelist.txt"), Object.entries(PROGRAMS).map(([key, [file, profile]]) =>
    filelistEntry(names[key], file, profile)).join("\r\n") + "\r\n");
  fs.writeFileSync(path.join(stage, "uniquefilestocopy.txt"), entries.map(([name]) => name).join("\r\n") + "\r\n");
  fs.mkdirSync(path.join(stage, "shaders/fxc"), { recursive: true });
  console.log(`Build ${build}\nStaging: ${stage}`);
  run(path.join(stage, "shadercompile.exe"), ["-nompi", "-allowdebug", "-game", game, "-shaderpath", stage],
    stage, path.join(stage, "compiler.log"));
  const reports = JSON.parse(run(flags.python || "python",
    ["-B", path.join(__dirname, "check_l2_vcs.py"), "--sm3-budget",
      ...Object.values(names).map(name => path.join(stage, "shaders/fxc", name + ".vcs"))],
    stage, path.join(stage, "bytecode-report.json")));
  for (const [key, name] of Object.entries(names)) validateReport(reports[name], key === "vertex");
  const output = Object.entries(names).map(([key, name]) =>
    ({ key, name, bytes: fs.readFileSync(path.join(stage, "shaders/fxc", name + ".vcs")) }));
  const manifest = { schema: 1, phase: "offline_candidate", gpuReady: false, build,
    adapter: "mc:sky_quad_v1", programs: Object.fromEntries(output.map(({ key, name, bytes }) =>
      [key, { name, sha256: sha256(bytes), bytes: bytes.length, profile: PROGRAMS[key][1],
        instructionHash: reports[name].instructionHash, instructionSlots: reports[name].instructionSlots }])) };
  const files = [...output.map(({ name, bytes }) => [path.join(ADDON, "shaders/fxc", name + ".vcs"), bytes]),
    [path.join(ADDON, "builds", build + ".json"), Buffer.from(JSON.stringify(manifest, null, 2) + "\n")]];
  for (const [file, bytes] of files) {
    if (fs.existsSync(file) && !fs.readFileSync(file).equals(bytes)) throw new Error(`Build-name collision: ${file}`);
  }
  for (const [file, bytes] of files) immutableWrite(file, bytes);
  fs.mkdirSync(path.dirname(DESCRIPTOR), { recursive: true });
  const temporary = DESCRIPTOR + `.tmp-${process.pid}`;
  fs.writeFileSync(temporary, JSON.stringify(descriptorDocument(manifest), null, 2) + "\n", { flag: "wx" });
  fs.renameSync(temporary, DESCRIPTOR);
  console.log(`Published sky vertex/pixel programs and descriptor: ${DESCRIPTOR}`);
}

module.exports = { validateReport, descriptorDocument };
if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.stack); process.exitCode = 1; }
}
