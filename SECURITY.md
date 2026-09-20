# Security policy

Do not open public issues for credentials, organization-access problems, or a policy
bypass. Use GitHub's private vulnerability reporting for this repository.

This repository must never contain access tokens, private keys, workflow secrets, or
generated API responses containing credentials. The reconciliation scripts use the
active `gh` authentication context at execution time.
