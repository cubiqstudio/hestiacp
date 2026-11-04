# VylarisSpace - Contribution guidelines

VylarisSpace is a private fork. Contributions are made by invitation of the repository owner, through pull requests in this repository.

## Ways to contribute

- **Code review and bug fixes**: read over the code and, if you notice errors (even spelling mistakes), submit a pull request with your changes.
- **New features**: submit a pull request with your changes. Please discuss larger changes in an issue first.
- **Translations**: the web interface uses gettext with the domain `hestiacp` (kept for compatibility, it is the name of the `.mo` files). Strings that contain the product name are English only until they are translated again.
- **Security reports**: do not use public issues, see [SECURITY.md](SECURITY.md).

## Development guidelines

Additional information is in the [Development](docs/docs/contributing/development.md) notes, which are inherited from upstream and may still show the old product name.

### Code formatting and comments

Follow the existing naming schemes and coding conventions, and add comments in your source code where appropriate to aid other developers in debugging and understanding your code in the future.

Run `npm ci` from the root of the repository before committing. This sets up pre-commit hooks for automatic formatting. `npm run lint` checks formatting, Biome rules and Markdown.

### Theme work

Build the assets with `npm run build` and verify visual changes with the preview and audit tooling in [test/vylaris-preview](test/vylaris-preview/README.md).

### Branches and pull requests

Always create a new topic branch from `vylaris-webspace` for your work and open the pull request against that branch.

Branch naming convention:

- **Prefix:** `topic/` (such as **fix**, **feature**, **refactor**, etc.)
- **ID**: `888` (GitHub issue ID if an issue exists)
- **Title:** `my-awesome-patch`

Examples:

- `feature/777-my-awesome-new-feature` or `feature/my-other-new-feature`
- `fix/000-some-bug-fix` or `fix/this-feature-is-broken`
- `refactor/v-change-domain-owner`

Please squash commits that belong together, for example "Fixed item 1" and "Adjusted alignment of button XYZ" into one commit with a descriptive title.

All pull requests must include a brief but descriptive title and a detailed description of the changes. Only include commits that are related to your feature, bug fix or patch.

### Naming rules

- The product is called **VylarisSpace** (one word) and the company **VylarisGroupEurope**. In the panel read the name from `$_SESSION["APP_NAME"]`, in scripts from `APP_NAME` in `hestia.conf`.
- Internal identifiers keep the historic name `hestia` (paths, services, users, `v-*` commands, config file names, the gettext domain, PHP namespaces). Do not rename them. The reasons are listed in [VYLARIS.md](VYLARIS.md).
- Do not add links to upstream sites to anything users see.

## License

By contributing you agree that your contribution is released under GPL-3.0-or-later.
