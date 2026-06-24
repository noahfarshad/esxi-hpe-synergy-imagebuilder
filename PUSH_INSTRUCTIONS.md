# Publishing esxi-hpe-synergy-imagebuilder to github.com/noahfarshad

The repo is ready — sanitized, documented, licensed (stub). Create it on GitHub and push.

---

## Prerequisites (one-time)

```powershell
# GitHub CLI if you don't have it
winget install GitHub.cli
gh auth login

# Git identity
git config --global user.name "Noah Farshad"
git config --global user.email "noah@essential.coach"
```

**Append the full GPL-3.0 license text** (the LICENSE file is currently a short stub):

```powershell
cd "path\to\esxi-hpe-synergy-imagebuilder"
Invoke-WebRequest -Uri "https://www.gnu.org/licenses/gpl-3.0.txt" -OutFile "LICENSE"
```

---

## Create + push

```powershell
cd "path\to\esxi-hpe-synergy-imagebuilder"

git init
git branch -M main
git add .
git commit -m "Initial release - Build-CustomEsxiIso v1.0.0, Validate-IsoVibs v1.0.0, Write-SoftwareSpec v1.0.0"

gh repo create noahfarshad/esxi-hpe-synergy-imagebuilder `
    --public `
    --description "Build a custom ESXi ISO bundling a VMware base depot with an HPE Synergy AddOn via PowerCLI Image Builder - so SAN-boot Synergy blades see their boot LUN at install time" `
    --homepage "https://essential.coach" `
    --source . `
    --push

git tag -a v1.0.0 -m "esxi-hpe-synergy-imagebuilder v1.0.0 - initial public release"
git push origin v1.0.0

gh repo edit noahfarshad/esxi-hpe-synergy-imagebuilder `
    --add-topic vmware `
    --add-topic esxi `
    --add-topic vsphere `
    --add-topic hpe `
    --add-topic synergy `
    --add-topic powercli `
    --add-topic image-builder `
    --add-topic boot-from-san `
    --add-topic homelab `
    --add-topic infrastructure
```

**Manual alternative (no gh CLI):**

1. <https://github.com/new> → name `esxi-hpe-synergy-imagebuilder`, public, no README/license
2. Then:
   ```powershell
   git remote add origin https://github.com/noahfarshad/esxi-hpe-synergy-imagebuilder.git
   git push -u origin main
   git tag -a v1.0.0 -m "esxi-hpe-synergy-imagebuilder v1.0.0 - initial public release"
   git push origin v1.0.0
   ```

---

## Post-push

- Create a GitHub Release for `v1.0.0`, paste the CHANGELOG v1.0.0 entry as the description.
- Publish the customer success story on essential.coach (slug suggestion: `custom-esxi-iso-hpe-synergy`).
- Add the story to the wordpress-publisher `get_stories()` and re-run `--publish --update-pages`.
- Add a repo card to the Automation Downloads page (under a new "Infrastructure & Imaging" section, or alongside the STIG tooling).

## Verify

```powershell
gh repo view noahfarshad/esxi-hpe-synergy-imagebuilder --web
git ls-remote --tags origin
```

Confirm no customer markers remain:

```powershell
git grep -i -E "leidos|qtc|broadcom professional" ; if ($LASTEXITCODE -eq 0) { Write-Host "FOUND MARKERS - fix before pushing" -ForegroundColor Red } else { Write-Host "Clean" -ForegroundColor Green }
```
