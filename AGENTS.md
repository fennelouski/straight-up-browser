# Browser releases

Before every release, review the current provider model catalogs, pricing, and API
compatibility using official sources. Follow `docs/agent-model-review.md`, update
current defaults and reviewed successor mappings where needed, and record the
review for the exact release version in `docs/agent-model-review.json`.

Do not blindly upgrade custom endpoints, installed local models, or dated pinned
snapshots. Keep model roles and provider boundaries intact. Future runs must use
pricing and run metadata for the actual selected model; leave historical runs
unchanged. Run the existing verification and signed release process in
`DEPLOYMENT.md`, including the live model-review gate.
