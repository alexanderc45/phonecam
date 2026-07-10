-- Runs automatically when BeamNG loads the mod.
-- Loads the phoneCamera GE extension and keeps it resident across
-- level (re)loads so the UDP listener survives map changes.
extensions.load('phoneCamera')
setExtensionUnloadMode('phoneCamera', 'manual')
