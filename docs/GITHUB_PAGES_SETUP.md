# GitHub Pages Setup For Steer Launch Pages

This repo now has static launch pages under `docs/`:

- `docs/index.html`
- `docs/privacy/index.html`
- `docs/terms/index.html`
- `docs/support/index.html`

## GitHub Pages Settings

In GitHub:

1. Open the repository settings.
2. Go to **Pages**.
3. Set **Source** to **Deploy from a branch**.
4. Set **Branch** to the launch branch or `main`.
5. Set **Folder** to `/docs`.
6. Save.

Without a custom domain, the expected URLs are:

- `https://ilwonyoon.github.io/steer_ai/privacy/`
- `https://ilwonyoon.github.io/steer_ai/terms/`
- `https://ilwonyoon.github.io/steer_ai/support/`

If `steer.ai` is ready, configure the custom domain in GitHub Pages and point DNS at GitHub Pages. Then use these canonical App Store URLs:

- `https://steer.ai/privacy/`
- `https://steer.ai/terms/`
- `https://steer.ai/support/`

Do not add `docs/CNAME` until the domain is actually configured, because a bad CNAME can break the fallback GitHub Pages URL.

## Pre-Submission Checks

- Replace any remaining launch placeholders in `docs/legal/PRIVACY_POLICY.md` and `docs/legal/TERMS_OF_SERVICE.md`.
- Confirm `superwedge.labs@gmail.com` receives support, privacy, and deletion requests.
- Confirm the public pages load in an incognito browser.
- In App Store Connect, use the live privacy URL and support URL.
- If custom Terms are used, use the live Terms URL or paste the custom EULA where App Store Connect expects it.
