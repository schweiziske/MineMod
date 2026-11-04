// Display fields of the published shader descriptors. They are translation
// keys only: the text lives in each addon's data_static/mc/i18n/ and is not a
// build input, so editing it never renames programs or requires a compile.
const fs = require("node:fs");
const path = require("node:path");
const DISPLAY = path.join(__dirname, "descriptor_display.json");
const FIELDS = ["nameKey", "descriptionKey"];
const KEY = /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/;

function displayFor(id) {
  const entry = JSON.parse(fs.readFileSync(DISPLAY, "utf8"))[id];
  if (!entry || typeof entry.nameKey !== "string") throw new Error(`No display keys for ${id} in ${DISPLAY}`);
  for (const [field, value] of Object.entries(entry)) {
    if (!FIELDS.includes(field) || typeof value !== "string" || value.length > 200 || !KEY.test(value))
      throw new Error(`Invalid display field ${field} for ${id} in ${DISPLAY}`);
  }
  return entry;
}

// The definition with its display fields replaced; they follow "schema".
function withDisplay(id, definition) {
  if (!("schema" in definition)) throw new Error(`Descriptor ${id} has no schema field`);
  const display = displayFor(id);
  const result = {};
  for (const [field, value] of Object.entries(definition)) {
    if (field === "name" || FIELDS.includes(field)) continue;
    result[field] = value;
    if (field === "schema") Object.assign(result, display);
  }
  return result;
}

module.exports = { displayFor, withDisplay };
