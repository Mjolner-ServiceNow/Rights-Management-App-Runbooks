# Notice

## Licence: not yet chosen

This repository is public and has **no licence file**. Under copyright law that means
all rights reserved: nobody, including the customer this was built for, has permission to
use, copy, modify or distribute it. GitHub's own guidance is explicit that public does not
mean open source.

That is almost certainly not the intent, since the Bicep template is meant to be deployed
by the customer. Someone with authority to decide should pick one:

| Option | When it fits |
|---|---|
| **MIT** | Simplest. Anyone may use it, no warranty, attribution required. |
| **Apache 2.0** | Like MIT, plus an explicit patent grant. Common for infrastructure code. |
| **Proprietary, with a written grant to the customer** | Keeps the code closed but permits the customer to deploy and modify it. Fits a three-year service agreement. |
| **Make the repository private** | If public was not a deliberate decision, this is the cheapest fix. |

Until then, the customer is technically not licensed to run the template.

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
