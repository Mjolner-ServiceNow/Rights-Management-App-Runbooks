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

**Read-only access to secrets.** The runtime identity holds `Key Vault Secrets User`. It
can read the two secrets it needs and cannot rotate, add or delete anything.

**Least privilege on the directory side.** The app registration is granted
`Exchange Recipient Administrator`, which covers every Exchange cmdlet the runbooks call.
Not Exchange Administrator, and not Global Administrator.

**Secrets cannot reach the logs by accident.** `Write-RmaLog` redacts values whose property
name suggests a secret, at any depth, and a custom analyzer rule blocks the pattern that
caused a real disclosure in the predecessor codebase: writing a whole payload object to the
job output.

**Jobs cannot execute twice.** Queue items are claimed with a conditional update that the
caller verifies it won. Without it, two concurrent runs both execute the same directory
write.

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
