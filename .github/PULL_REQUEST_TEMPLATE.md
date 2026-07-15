## Summary

<!-- What changed and why? -->

## Type of Change

- [ ] Bug fix
- [ ] Feature
- [ ] Documentation
- [ ] Release or packaging
- [ ] Maintenance

## Validation

- [ ] `scripts/validate-local.bash` (or `scripts/validate-local.bash --required-only` with optional local-tool skips noted)
- [ ] `bash -n gos.sh install.sh`
- [ ] `shfmt -d -i 2 -ci -bn .`
- [ ] `shellcheck gos.sh install.sh completions/gos.bash scripts/*.bash scripts/*.sh tests/*.bash`
- [ ] `scripts/sync-command-surfaces.bash --check`
- [ ] `bash tests/completions.bash`
- [ ] `bash tests/workflows.bash`
- [ ] `bash tests/install-transaction.bash`
- [ ] `bash tests/checksum.bash`
- [ ] `bash tests/features.bash`
- [ ] Other:

## Notes

<!-- Mention platform-specific behavior, docs updates, or follow-up work. -->
