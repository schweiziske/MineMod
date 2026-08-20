-- Client decoration renderer entry point.
-- Split by the corresponding Java renderer so each transform remains auditable.
if not CLIENT then return end
MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}

-- mcgame_load.lua loads the renderer modules in dependency order before this
-- entry point.  Do not include them here: doing so recreates materials and
-- module-local caches a second time on every client autorun.
