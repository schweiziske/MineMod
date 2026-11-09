const fs = require("node:fs");
const path = require("node:path");

// Call only after publication. Never infer the live set from a build fingerprint.
function pruneOldShaders(addon, descriptor, prefix) {
  if (!/^mc_[a-z0-9_]+_$/.test(prefix)) throw new Error("Invalid shader cleanup prefix");
  const root = fs.realpathSync(addon);
  const directory = fs.realpathSync(path.join(root, "shaders/fxc"));
  const relative = path.relative(root, directory);
  if (path.isAbsolute(relative) || relative === ".." || relative.startsWith(".." + path.sep)) {
    throw new Error("Shader directory must stay inside its addon");
  }
  const bytes = fs.readFileSync(descriptor, "utf8");
  const document = JSON.parse(bytes);
  const programs = document.definition && document.definition.programs;
  if (document.schema !== 1 || !programs || typeof programs !== "object"
      || Array.isArray(programs) || Object.keys(programs).length === 0) {
    throw new Error("Cannot clean shaders without a published program table");
  }
  const keep = new Set();
  for (const program of Object.values(programs)) {
    for (const [stage, suffix] of [["vertex", "_vs30"], ["pixel", "_ps30"]]) {
      const name = program && program[stage];
      if (typeof name !== "string" || !/^[a-z0-9_]+$/.test(name) || !name.endsWith(suffix)) {
        throw new Error(`Invalid published ${stage} shader name`);
      }
      keep.add(name + ".vcs");
    }
  }
  // A broken/incomplete publication must not remove the previous working build.
  for (const name of keep) {
    const info = fs.lstatSync(path.join(directory, name));
    if (!info.isFile() || info.size === 0) throw new Error(`Missing published shader: ${name}`);
  }
  const owned = new RegExp("^" + prefix + "[a-z0-9_]+_[0-9a-f]{20}_(?:vs|ps)30\\.vcs$");
  const old = fs.readdirSync(directory, { withFileTypes: true })
    .filter(entry => entry.isFile() && owned.test(entry.name) && !keep.has(entry.name))
    .map(entry => entry.name).sort();
  if (fs.readFileSync(descriptor, "utf8") !== bytes) throw new Error("Descriptor changed during shader cleanup");
  for (const name of old) fs.unlinkSync(path.join(directory, name));
  console.log(`Removed ${old.length} old shader files from ${path.basename(root)}`);
  return old;
}

module.exports = { pruneOldShaders };
