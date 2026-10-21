# Backups and troubleshooting

[Documentation](README.md) · [Proxmox operations](proxmox.md#updates-and-backups)

## Data and backups

Back up the file at `PERCH_DATA`. To restore it, stop Perch, copy the backup into place, and restart.

Saves write a synced temporary file and atomically rename it into place. Failed writes leave the in-memory collection intact. An unreadable or malformed existing collection stops startup rather than replacing it. Reordering validates the complete app list before saving.

Run **one Perch process per data file**. Other browser tabs see changes after reloading; concurrent edits use last-write-wins semantics. Up to 256 apps are supported, with names limited to 80 characters and stored logos to 48 KB. Older category, favorite, and description fields are retained for compatibility but have no interface or ordering effect.

The default data directory is ignored by Git. If you set `PERCH_DATA` elsewhere inside the checkout, add that location to `.gitignore` before committing.

A missing collection file starts an empty dashboard. A malformed or unreadable existing file stops startup. Keep the original file and inspect the error before making changes; deleting it can make the dashboard appear empty without recovering anything.

Uploaded logos are included in the JSON backup. Bundled logos ship with the binary. Remote image URLs remain dependent on their source; backing up the collection does not copy those images.

## Restore a native installation

1. Stop the process or service that uses the collection.
2. Keep a copy of the current collection in case you need to undo the restore.
3. Copy the backup to the path configured by `PERCH_DATA`.
4. Ensure the service user can read the file and write its parent directory.
5. Restart Perch and reload the dashboard.

For a packaged systemd installation, use `/var/lib/perch/apps.json`, owner `perch:perch`, directory mode `0750` and file mode `0640`. Run `systemctl stop perch` before restoring and `systemctl start perch` afterwards. Proxmox host commands are in the [container guide](proxmox.md#updates-and-backups).

## Common problems

| Symptom | What to check |
| --- | --- |
| Another device cannot connect | Bind to a LAN-reachable interface; check the server IP, port and firewall. Native builds default to loopback port 3000; packaged LXC installs default to port 80. |
| Startup fails | Read terminal output or service logs. Check the port is available, the configured data path is correct and existing JSON is valid. |
| Changes cannot be saved | The process needs write access to both the collection and its directory. Check free disk space and read-only mounts. |
| Dashboard is unexpectedly empty | Check `PERCH_DATA` and the working directory. A different relative path can create a new collection. |
| Another tab shows old data | Reload it. There is no background synchronisation. |
| Reordering reports that the list changed | Reload to get the current list, then reorder again. |
| A logo is missing | Check the service URL, certificate and browser mixed-content rules; try a bundled or uploaded logo. See the [logo guide](user-guide.md#how-automatic-logos-work). |
| Asset changes do not appear during development | Rebuild or restart `cargo run`; assets are embedded at compile time. Reload the browser. |

## Service diagnostics

For a systemd installation, run inside the machine or container:

```sh
systemctl status perch --no-pager
journalctl -u perch -n 100 --no-pager
curl -f http://127.0.0.1/api/apps
```

Use your configured port in the URL if it differs from 80. For Docker, inspect `docker logs perch` and confirm the data mount is writable by UID/GID `10001:10001`.

When reporting a problem, include the version, installation method, OS/architecture, steps to reproduce and relevant errors. Remove private hostnames, addresses and collection contents from shared logs.
