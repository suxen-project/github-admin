# suxen-project GitHub administration

This repository is the reviewable source of truth for GitHub repository settings,
security controls, Actions permissions, and rulesets in the `suxen-project`
organization. It contains no credentials and no generated state.

## Repository policy

Managed repositories use:

- squash merges and automatic head-branch deletion;
- pull requests for changes to the default branch;
- resolved review conversations and repository-specific required checks;
- blocked force pushes and default-branch deletion;
- read-only default `GITHUB_TOKEN` permissions;
- Dependabot alerts and security updates, secret scanning with push protection,
  and private vulnerability reporting.

The organization currently has one member, so the pull-request rule requires no
external approval. Requiring one approval would prevent the sole member from merging
their own changes. Raise the configured approval count when another maintainer joins.

## Usage

Authenticate the GitHub CLI as an organization owner, then run:

```console
make validate
make audit
make apply
```

`make audit` is read-only and reports drift. `make apply` reconciles every JSON file in
`config/repositories/` and then audits the result. The scripts default to
`suxen-project`; set `GITHUB_ORGANIZATION` only when testing against another
organization.

Add a repository by committing another `config/repositories/<name>.json` file. Changes
to live administration should flow through a pull request here before running
`make apply` from a trusted maintainer workstation.

If a bad rule prevents recovery, an organization owner can disable it with the GitHub
settings UI or API. Update the corresponding JSON in the same recovery change so the
next audit does not reintroduce stale policy.
