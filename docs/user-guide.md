# Using Perch

[Documentation](README.md) · [Installation](installation.md)

Perch is a grid of shortcuts to your homelab services. It does not monitor service availability. JavaScript must be enabled in your browser.

## Add an app

1. Select **Add app**.
2. Enter a name and a URL or IP address.
3. Optionally expand **Logo** to choose an image.
4. Select **Add app** to save.

Addresses without a scheme receive `http://`. Include `https://` explicitly for HTTPS services. Ports, paths and IPv6 are supported:

| Example | Use |
| --- | --- |
| `192.168.1.10:8096` | A service on a custom port |
| `https://nas.local/files/` | An HTTPS service with a path |
| `http://[fd00::10]:8096` | An IPv6 service |

Use HTTP or HTTPS addresses without embedded usernames or passwords. Names may contain up to 80 characters. In normal mode, select a tile to open the service.

## Edit, reorder or remove apps

Select the **pencil** button to enter editing mode. Select a tile or its three-dot button to open the editor, change its fields, then save. Cancel closes the editor without saving field changes.

Drag a tile by its handle to move it, or use its left/right buttons to move it earlier or later. These buttons also work with keyboard focus and activation. Ordering saves as you move items; select the **checkmark** to leave editing mode.

To remove a shortcut, open its editor, select the trash button, then confirm **Remove**. This removes the shortcut from Perch; the linked service is unaffected.

## Choose a logo

Expand **Logo** in the app editor and choose:

- **Automatic from URL** to try the service's favicons.
- A bundled logo for a supported service or the generic server icon.
- An **Image URL** pointing directly to an HTTP(S) image.
- **Upload image** for PNG, JPEG or WebP. The browser resizes uploads to at most 128 × 128 pixels and stores the result in the collection.

All logos appear in greyscale. Uploaded logo data is limited to 48,000 characters, including its data URL prefix. If an image is too large, choose a simpler image.

## How automatic logos work

Your browser tries a favicon under the app's path, then `/favicon.ico`, `/favicon.svg`, and `/apple-touch-icon.png` on the service's own origin. Ports are preserved. Requests send no referrer and use a 2.2-second limit per candidate. Images resolve only as tiles approach the viewport, and results are reused for the lifetime of the page.

The Rust server does not fetch or proxy services. There is no third-party favicon service, availability monitoring, or recurring discovery. A bundled or generic server icon appears while resolving and remains if all candidates fail.

Automatic resolution is best effort. Services with icons declared only through HTML metadata, authentication requirements, untrusted certificates, or mixed-content restrictions may need a direct image URL or uploaded logo. Browsers may log failed favicon candidates before the next one succeeds.

## Multiple devices and browser tabs

Changes are saved on the server. Reload other tabs or devices to see them. Concurrent edits use last-write-wins semantics; a reorder using an outdated app list is rejected, so reload before trying again.

Perch supports up to 256 apps. See [backups and troubleshooting](operations.md) for storage limits, recovery and connection problems.
