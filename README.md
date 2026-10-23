# Soduto landing page

Source for [soduto.hidoba.com](https://soduto.hidoba.com), hosted on Cloudflare Pages.

This independent `codex/website` branch contains only the website. The Mac app lives on [`codex/reliability-diagnostics`](https://github.com/hidoba/Soduto/tree/codex/reliability-diagnostics). Keep the branches separate; there is no need to merge website files into the app or create a separate repository.

## Develop

Use Node.js 24 or newer:

```sh
npm ci
npm run build
npm run check
npm run dev
```

Open `http://localhost:8788`. The site uses HTML, CSS and JavaScript, with no frontend framework. The device and clipboard previews are original HTML/CSS illustrations with example content, not captures of a real user's devices. The app icons come from Soduto and retain its GPL v3 license.

## Latest app commit and download

`npm run build` fetches the latest commit from the **app branch** and the latest public release. It embeds the date and download links into the HTML and saves a fallback in `public/project.json`. The date uses UTC.

The Cloudflare Pages Function at `/api/project` refreshes this information, cached for five minutes, without redeploying the site. If GitHub is unavailable or rate-limited, the saved snapshot remains visible. No visitor tracking, accounts, cookies, or analytics are added.

The repo and app branch are defined in `lib/project.js`. If you fork or rename either, update that file, canonical links, and site content.

## Deploy to Cloudflare Pages

Export `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` in your shell, then run:

```sh
npm run deploy
```

The Pages project is `soduto-hidoba`, with production branch `codex/website` and custom domain `soduto.hidoba.com`. The deployment uses Wrangler Direct Upload, including the small metadata function. Builds and checks run locally; deployment is manual. GitHub Actions is disabled. Credentials stay in your shell and are not stored in this repository.

## Assets and previews

`public/assets/soduto.png`, `soduto.webp`, and `menu-icon.png` originate from Soduto. The Mac, Ubuntu, Windows, Android and iPhone illustrations are rendered with HTML/CSS in `public/index.html`. The diagram shows text, an image and a single file together, without format tabs. Meaningful labels remain at least 12 CSS pixels at narrow widths. Phone previews stay text-only to reflect the clients’ clipboard support. The badge PNGs use the app’s production drawing method. `native-menu.png` is an AppKit-rendered preview using `DeviceMenuPresentation` from app commit `91c2182`, with example device names. It is explicitly labeled as a source preview: the published build 35 predates that menu redesign. No Cap artwork or source code is used.

The mobile notes distinguish receiving computer text from manually sending phone text, and link to the Android clipboard implementation and iOS limitations. SMS and notification sync are described as Android features; the page notes that inherited services are still being tested.

Licensed under [GNU GPL v3](LICENSE). Thanks to [sannidhyaroy/Soduto](https://github.com/sannidhyaroy/Soduto) and [soduto/Soduto](https://github.com/soduto/Soduto).
