# Security

## Reporting a vulnerability

Do not open a public issue, and do not include credentials or customer data in a report.
Contact the repository owners directly and allow reasonable time to respond before any
disclosure.

## Design posture

This code has write access to Active Directory and Microsoft Entra ID in the environments
where it runs, so a few properties are deliberate rather than incidental.

**No long-lived credentials anywhere.** The workload authenticates with a user-assigned
managed identity, federated to an app registration. No client secret, no certificate. The
two passwords that cannot be federated, for ServiceNow and the AD service account, live in
Key Vault and are read at run time.

**Read-only access to secrets.** The runtime identity holds `Key Vault Secrets User` on
the vault. It cannot rotate, add or delete anything, but it can read *every* secret in that
vault, not only the two it needs. Keep nothing else in it.

**Broad directory permissions, deliberately scoped to one role in Exchange.** The app
registration holds tenant-wide Microsoft Graph *application* permissions, among them
`User.ReadWrite.All`, `Group.ReadWrite.All`, `User-PasswordProfile.ReadWrite.All` and
`UserAuthenticationMethod.ReadWrite.All` — the full list is in
[`docs/AZURE-RESOURCES.md`](docs/AZURE-RESOURCES.md). Application permissions are not
limited to a subset of users, so whoever can act as the app registration can change any
user in the tenant. In Exchange the app is granted `Exchange Recipient Administrator`,
which covers every Exchange cmdlet the runbooks call: not Exchange Administrator, and not
Global Administrator.

**Logging redacts secret-like names and secrets inside text.** `Write-RmaLog` passes its
`-Message` and every `-Data` value through `ConvertTo-RmaSafeLogValue`, at any depth:

- A key or property is redacted when its name, ignoring case, `_`, `-`, `.` and spaces,
  contains `password`, `passwd`, `pwd`, `secret`, `token`, `credential`, `authorization`,
  `assertion`, `thumbprint`, `cookie`, `connectionstring`, or `apikey`, `privatekey`,
  `accountkey`, `accesskey`, `clientkey`, `signingkey` or `sharedkey`. So `access_token`,
  `client_secret` and `adPassword` are caught.
- Every string, the message included, is scanned for `Bearer` and `Basic` credentials,
  JWTs, `key=value`, `key: value` and `"key":"value"` pairs whose key looks like a secret,
  and SAS `sig=` signatures.

It is a pattern match, not a guarantee: a secret under an innocent name, or in a format it
does not know, still gets through. A custom analyzer rule blocks the pattern that caused a
real disclosure in the predecessor codebase, writing a whole payload object to the job
output, including passing one whole to `Write-RmaLog`. Both are defence in depth; log
named, non-secret fields and build messages from constant text.

**Jobs are meant to execute once, and today can execute twice.** Queue items are claimed
with a conditional update that the caller verifies it won. ServiceNow's Table API ignores
the condition on a single-record update (found on a test instance on 2026-09-30), so two
concurrent runs that read the same Pending row can both execute the same directory write.
The fix is a server-side compare-and-set; see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#job-lifecycle) and
[`HANDOVER.md`](HANDOVER.md). Until it lands, command bodies must be idempotent.

## The security boundary

Anyone who can execute code on the Hybrid Worker VM can request the managed identity's
token from IMDS, and therefore act as the app registration and read the Key Vault secrets.

That is inherent to running there, and it is not worse than the alternative: a certificate
or secret on the same VM is equally reachable and additionally exportable. But it means
**the worker VM is a Tier 0 asset** and should be governed as one: no interactive logon,
just-in-time administrative access, endpoint protection, and change control over what runs
on it.

## If you find a credential in the history

Rotate it first, then remove it. Rewriting history does not un-publish anything that was
public, and this repository is public.
