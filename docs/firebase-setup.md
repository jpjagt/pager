# Firebase setup (one-time)

1. Go to https://console.firebase.google.com → Add project (any name, e.g.
   `pager`). Disable Analytics — not needed.
2. Build → Realtime Database → Create Database. Pick a region (e.g.
   europe-west1). Start in **locked mode**.
3. In the Rules tab, replace the contents with `firebase/rules.json` from
   this repo and publish.
   > **Note (2026-08):** image support changed `firebase/rules.json` — nodes
   > gained an optional `type` field and the `ct` length cap is now conditional
   > (1,000,000 chars for `type: "img"`, 2048 otherwise). Databases set up
   > before this must re-publish the rules from the repo, or image writes are
   > rejected.
4. Copy the database URL shown at the top of the Data tab, e.g.
   `https://bff-pager-default-rtdb.europe-west1.firebasedatabase.app`.
5. Paste it into `Sources/PagerCore/PagerConfig.swift` as
   `databaseURLString` and commit.

Privacy model: the URL is not a secret. Pager nodes live at unguessable
HKDF-derived paths and contents are AES-GCM encrypted with keys derived from
share codes that never leave the devices. Root-level read/list is denied, so
nodes cannot be enumerated.
