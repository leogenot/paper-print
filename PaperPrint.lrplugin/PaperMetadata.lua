-- Hidden per-photo field (no title, so it never shows in the Metadata panel).
-- Stores the paper parameters plus the photo's own settings underneath the effect,
-- so re-opening the dialog edits the existing paper instead of stacking a second one.
return {
  metadataFieldsForPhotos = {
    { id = "state", dataType = "string" },
  },
  schemaVersion = 1,
}
