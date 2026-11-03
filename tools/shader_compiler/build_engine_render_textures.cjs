// Neutral material channels for color-only engine/texture-pack atlases.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const zlib = require("node:zlib");
const { immutableWrite } = require("./build_l2_vanilla.cjs");
const ROOT = path.resolve(__dirname, "../..");
const ENGINE = path.join(ROOT, "addons/mc_engine");
const MANIFEST = path.join(ENGINE, "data_static/mc/render_textures.json");
const sha256 = bytes => crypto.createHash("sha256").update(bytes).digest("hex");

function constantPNG(rgba) {
  function chunk(type, data) {
    const payload = Buffer.concat([Buffer.from(type), data]);
    const size = Buffer.alloc(4), checksum = Buffer.alloc(4);
    let crc = 0xffffffff;
    for (const byte of payload) {
      crc ^= byte;
      for (let i = 0; i < 8; ++i) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    size.writeUInt32BE(data.length); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([size, payload, checksum]);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1, 0); header.writeUInt32BE(1, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(Buffer.from([0, ...rgba]))), chunk("IEND", Buffer.alloc(0))]);
}

function publishedResources() {
  const { resources } = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  const expected = ["normal", "orm"].sort();
  if (JSON.stringify(Object.keys(resources).sort()) !== JSON.stringify(expected))
    throw new Error("Engine material defaults must contain only neutral normal and LabPBR maps");
  for (const [name, resource] of Object.entries(resources)) {
    if (!/^materials\/mc\/render\/[a-z0-9_]+\.png$/.test(resource.path)
        || resource.colorSpace !== "linear"
        || sha256(fs.readFileSync(path.join(ENGINE, resource.path))) !== resource.sha256)
      throw new Error(`Invalid engine render resource: ${name}`);
  }
  return { resources, materialMaps: {}, bytes: Buffer.from(JSON.stringify(resources)) };
}

function main(argv) {
  if (argv.length) throw new Error("Usage: node tools/shader_compiler/build_engine_render_textures.cjs");
  const textures = { normal: constantPNG([128, 128, 255, 255]), orm: constantPNG([0, 10, 0, 255]) };
  const resources = {};
  for (const [name, bytes] of Object.entries(textures)) {
    const hash = sha256(bytes), resourcePath = `materials/mc/render/${name}_${hash.slice(0, 20)}.png`;
    immutableWrite(path.join(ENGINE, resourcePath), bytes);
    resources[name] = { path: resourcePath, sha256: hash, colorSpace: "linear" };
  }
  fs.mkdirSync(path.dirname(MANIFEST), { recursive: true });
  fs.writeFileSync(MANIFEST, JSON.stringify({ schema: 1, resources }, null, 2) + "\n");
  publishedResources();
  console.log(`Published ${Object.keys(resources).length} engine render textures: ${MANIFEST}`);
}

module.exports = { constantPNG, publishedResources };
if (require.main === module) main(process.argv.slice(2));
