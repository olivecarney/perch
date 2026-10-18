# Perch minimal interface implementation

Implemented against design.md and the user's requested simplification.

- Remove organization and decorative copy from the visible interface. Keep only brand, Add app, editing toggle, and logo/name tiles.
- Default new entries to automatic favicon resolution. Try bounded origin/subpath candidates in the browser, with lazy loading, cached results, and bundled fallbacks. Keep optional URL/upload/bundled overrides collapsed.
- Persist array reordering through an exact ID permutation, rejecting missing/duplicate/unknown IDs. Support pointer handles and accessible earlier/later buttons; restore the existing order on canceled or failed changes.
- Preserve legacy JSON values without exposing them. Test minimal payload defaults, durable order, stale IDs, URL candidates, CRUD, and failure paths.
- Verify actual browser add/edit, logo fallback/override, drag/button reordering and reload at desktop/mobile widths. Use a separate temporary QA collection; do not seed the user's dashboard.
