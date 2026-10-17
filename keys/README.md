# Signing keys

`qa.pub` and `release.pub` are placeholders. They are not Ed25519 public keys and they do not approve a bundle.

The master installer accepts the offline catalog only when `catalog/catalog.sha256` matches `catalog/catalog.json` and the catalog says `signatureStatus: placeholder-untrusted`. A catalog that claims to be release-signed is rejected, because this build cannot verify a real signature and must not pretend that it did.

Generate and store real `qa-2026` and `release-2026` keys offline before any production approval. Do not put private keys in git.
