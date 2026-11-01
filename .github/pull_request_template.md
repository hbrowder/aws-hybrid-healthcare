## What changed and why

<!-- One or two sentences. -->

## Terraform plan

<!-- Paste the Plan line from: terraform plan -out tfplan -->
`Plan: _ to add, _ to change, _ to destroy`

Anything destroyed or replaced, and why:

## Checklist

- [ ] `terraform fmt` and `terraform validate` pass locally
- [ ] Plan reviewed: no unexpected destroy or replace
- [ ] No keys, passwords, state or plan files in this PR
- [ ] Cost impact noted (if any)
- [ ] Firewall config regenerated if tunnel values change

## How it was tested

<!-- e.g. checks 1-10, curl "sees you as 100.64.1.10", dashboard alarms OK -->

## Rollback

<!-- e.g. revert this PR and apply, or terraform destroy -->
