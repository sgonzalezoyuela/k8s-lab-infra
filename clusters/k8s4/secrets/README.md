# secrets/

Holds CA material and other secrets. Everything in this directory is gitignored
except this README and `.gitkeep`. See `.ai/architecture.md` for the layout.

`ca.crt` is the operator CA. It is consumed by cert-manager (paired with `ca.key`) AND, when `TALOS_TRUSTED_CA_PATH=secrets/ca.crt` is set in `.env`, trusted by every Talos node via a TrustedRootsConfig. NOTE: if you replace `ca.crt` you must also replace `ca.key` with the matching private key, or cert-manager-install will fail its pubkey-match check.
