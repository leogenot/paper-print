return {
  LrSdkVersion = 10.0,
  LrSdkMinimumVersion = 6.0,

  LrToolkitIdentifier = "io.paperprint.lightroom",
  LrPluginName = "Paper Print",
  LrPluginInfoUrl = "",

  LrMetadataProvider = "PaperMetadata.lua",

  -- File > Plug-in Extras (available in Library and Develop)
  LrExportMenuItems = {
    { title = "Paper Print…", file = "ShowDialog.lua", enabledWhen = "photosSelected" },
    { title = "Remove Paper Print", file = "RemoveEffect.lua", enabledWhen = "photosSelected" },
  },

  -- Library > Plug-in Extras
  LrLibraryMenuItems = {
    { title = "Paper Print…", file = "ShowDialog.lua", enabledWhen = "photosSelected" },
    { title = "Remove Paper Print", file = "RemoveEffect.lua", enabledWhen = "photosSelected" },
  },

  VERSION = { major = 0, minor = 3, revision = 0, build = 1 },
}
