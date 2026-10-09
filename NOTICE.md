# Notice

## Licence

Released under the [MIT Licence](LICENSE), copyright Mjølner Informatics A/S.

MIT was chosen because the provisioning scripts and the shared module are meant to be
deployed and adapted by the customer in their own tenant. MIT grants that without
conditions beyond preserving the copyright notice, and carries no warranty.

If a patent grant is wanted, Apache 2.0 is the usual alternative and is a drop-in
replacement.

## What this repository does and does not contain

**Contains:** PowerShell source, two GitHub Actions workflows, tests and documentation.
Neither workflow has Azure credentials or repository secrets, and neither deploys
anything; both use only the automatic `GITHUB_TOKEN`. `ci.yml` validates, with
`contents: read` and `pull-requests: write`. `release.yml` has `contents: write`, so it can
draft and publish GitHub releases of the module package.

**Does not contain:** credentials, connection strings, certificates, tenant or subscription
identifiers, ServiceNow instance names, or any customer data. Test fixtures use `contoso`
and synthetic GUIDs.

The GUIDs that do appear in the source and the documentation are Microsoft's own well-known
identifiers, documented publicly and identical in every tenant, plus the module's own
manifest `GUID`, which identifies `RMA.Runbooks` and nothing else:

| GUID | What |
|---|---|
| `4633458b-17de-408a-b874-0445c86b69e6` | Key Vault Secrets User role |
| `b86a8fe4-44ce-4948-aee5-eccb2c155cd7` | Key Vault Secrets Officer role |
| `f353d9bd-d4a6-484e-a77a-8050b599b867` | Automation Contributor role |
| `00000003-0000-0000-c000-000000000000` | Microsoft Graph application id |
| `00000002-0000-0ff1-ce00-000000000000` | Office 365 Exchange Online application id |
| `dc50a0fb-09a3-484d-be87-e023b12c6440` | Exchange `Exchange.ManageAsApp` app role |

## Reporting a security issue

Do not open a public issue. Contact the repository owners directly. See
[`SECURITY.md`](SECURITY.md).
