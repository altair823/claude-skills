# harbor-ops config without Bitwarden

Read this only when a profile cannot use `_USER_REF` / `_SECRET_REF` (for example a CI
robot account on a machine without bitwarden-ops).

## Credentials

- Personal use: Harbor *User Profile → CLI Secret → Generate*.
- CI: a robot account secret.

## Inline or file secrets

```
HARBOR_DEFAULT_PROFILE=prod

prod_HARBOR_URL=https://harbor.example.com
prod_HARBOR_USER=alice
prod_HARBOR_SECRET=<cli-secret-or-robot-secret>

# Secret kept in a separate file
staging_HARBOR_URL=https://harbor-staging.example.com
staging_HARBOR_USER=alice
staging_HARBOR_SECRET_FILE=~/.config/harbor-ops/secrets/staging
```

- `chmod 600` the config and any secret file. Never commit a config with inline secrets.
  For dotfile sync, use `_HARBOR_SECRET_FILE` and keep the secret file out of version control.
- **Quote `$` values.** Robot accounts (`robot$<name>`) and many secrets contain `$`.
  The config is shell-sourced, so an unquoted `$foo` is expanded and the credential is
  silently wrong. Single-quote them: `prod_HARBOR_USER='robot$readonly'`.

## File encoding

The config is shell-sourced. It must be UTF-8 without BOM: a BOM corrupts the first
variable name and breaks auth. PowerShell's default `>` / `Out-File` writes UTF-16 LE
with BOM; use `Set-Content -Encoding utf8NoBOM` or `[IO.File]::WriteAllText()`.

## Windows

Git Bash 2.x (bash 4.4+) and WSL2 work. NTFS ignores `chmod`, so mode 0600 is
best-effort on native Git Bash; rely on user-directory ACLs.
