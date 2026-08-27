# Notice

## Licence

Released under the [MIT Licence](LICENSE), copyright Mjølner Informatics A/S.

MIT was chosen because the Bicep template, the provisioning scripts and the shared module
are meant to be deployed and adapted by the customer in their own tenant. MIT grants that
without conditions beyond preserving the copyright notice, and carries no warranty.

If a patent grant is wanted, Apache 2.0 is the usual alternative and is a drop-in
replacement.

## What this repository does and does not contain

**Contains:** PowerShell source, a Bicep template, a CI workflow, tests and documentation.
The CI workflow has no Azure credentials and no repository secrets, and it deploys nothing.

**Does not contain:** credentials, connection strings, certificates, tenant or subscription
identifiers, ServiceNow instance names, or any customer data. Test fixtures use `contoso`
and synthetic GUIDs.

The three GUIDs that do appear in the source are Microsoft's own well-known identifiers,
documented publicly and identical in every tenant:

| GUID | What |
|---|---|
| `4633458b-17de-408a-b874-0445c86b69e6` | Key Vault Secrets User role |
| `b86a8fe4-44ce-4948-aee5-eccb2c155cd7` | Key Vault Secrets Officer role |
| `dc50a0fb-09a3-484d-be87-e023b12c6440` | Exchange `Exchange.ManageAsApp` app role |

## Reporting a security issue

Do not open a public issue. Contact the repository owners directly. See
[`SECURITY.md`](SECURITY.md).
