# Review agent models before every release

The offline model picker and defaults must match current provider offerings.
Review them for every release, even when the release changes unrelated code.

1. Read the current official [OpenAI model catalog](https://developers.openai.com/api/docs/models),
   [Claude models](https://platform.claude.com/docs/en/models/overview),
   [Gemini models](https://ai.google.dev/gemini-api/docs/models), and
   [OpenRouter catalog](https://openrouter.ai/models). Check the model pages for
   standard pricing, tools, reasoning controls, request parameters, and availability.
   Apple Intelligence follows the installed OS; Ollama, LM Studio, and custom
   providers use their live local/account catalogs rather than guessed defaults.
2. Update `BrowserAgentProvider.defaultModel`, `AgentModelCatalog.swift`, and
   `AgentModelMigration.swift` when a successor is appropriate. Keep fast models
   fast, balanced models balanced, and flagship models in their existing role.
   Exact reviewed aliases migrate; custom and dated IDs stay unchanged. Verify
   the replacement through each provider, including OpenRouter's own IDs.
3. Check adapter compatibility and migration tests. Update pricing together with
   model IDs. Never transfer old rates to a new model or rewrite historical runs.
   Existing scheduled task configurations resolve reviewed aliases when starting
   future runs, and their new run snapshots record the actual resolved model.
4. After completing the review, record the exact new Mac marketing version, UTC
   review date, findings, source file SHA-256 values, and public source digests in
   `agent-model-review.json`. Update the source URLs when the selected models
   change. Source digests use `source_digest` in `scripts/check-agent-model-review.py`:
   whitespace-normalized Markdown, Google's main model content, OpenAI's featured
   models, and the required OpenRouter IDs. Do not refresh hashes simply to silence
   a failure; inspect the changed provider information first.
5. Run `python3 scripts/check-agent-model-review.py --live` and the normal release
   checks. Verification requires a matching release version, reviewed source files,
   and a review no more than seven days old. Release packaging fetches the public
   sources again and stops if model, pricing, or availability information changed.
   These checks use no API keys and make no billable inference requests.

The settings picker automatically refreshes an authenticated provider's model
list on opening, retains a manual refresh, and filters reviewed superseded aliases
from suggestions. Typing custom model IDs remains supported.
