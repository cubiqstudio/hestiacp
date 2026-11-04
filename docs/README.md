# Documentation site (internal)

This folder holds the VitePress documentation inherited from the upstream HestiaCP project. In VylarisSpace it is an internal reference only and is not published anywhere yet.

- The page content has not been rewritten. It still describes upstream HestiaCP in many places (name, install commands, links), so it must not be shown to customers as it is.
- The site configuration (`.vitepress/config.js`) no longer contains upstream social links, the "edit this page" link, the upstream search credentials, the donation, team, demo and forum entries or the upstream sitemap host. Building or serving the site therefore does not contact upstream services.
- Build and tests: `npm run docs:build`, `npm run docs:test`.
- The files `donate.md` and `team.md` are still in the tree (the start page links to the donation page) but are not part of the navigation. They have to be removed together with the start page link before any public release of this site.

See `NOTICE` and `VYLARIS.md` in the repository root for the origin of the project and the branding rules.
