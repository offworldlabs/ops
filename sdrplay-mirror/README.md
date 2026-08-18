# sdrplay-mirror

Uploads a local file into the SDRplay mirror bucket (Cloudflare R2), so
owl-os's OS image build has a stable static URL to download the SDRplay RSP
API installer and SDRconnect from, instead of depending on sdrplay.com's
website directly.

**Why this exists.** owl-os's build downloads these two files from sdrplay.com
at image-build time. That stopped being reliable in two independent ways: the
download flow now redirects through a WordPress Download Manager page into a
personal SharePoint/OneDrive account with a per-request auth token (fine for a
person clicking a button, not for an unattended build), and the site
separately sits behind a Cloudflare bot challenge that a scripted request
cannot solve. This mirrors the files into infrastructure we control instead.

**How it is invoked.** Manually, not on a schedule — there is nothing to run
periodically here, only to re-run by hand if SDRplay changes the upstream file
again. See `sdrplay-mirror.sh`'s own usage comment.

**Configuration.** `sdrplay-mirror.env.example` documents the required
non-secret config (R2 endpoint, bucket name, credentials file path). Copy it
outside this repository and fill in real values, or point the script at your
own copy with `SDRPLAY_MIRROR_CONFIG`.

**Credentials.** An R2 API token scoped to Object Read & Write on this bucket
only, generated in the Cloudflare dashboard under R2 -> Manage API Tokens.
Stored in a separate file (mode 600), referenced by path via
`R2_CREDENTIALS_FILE` — never committed, not even as a placeholder.

**Public read access.** This bucket must have public access enabled (the
`pub-<hash>.r2.dev` subdomain, or a mapped custom domain) for owl-os's build to
fetch the file with a plain unauthenticated GET — the upload endpoint
(`R2_ENDPOINT`, R2's S3-compatible API) is a *separate* URL from the public
read URL that ends up pinned in owl-os's `versions.yml`.
