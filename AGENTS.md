# Lively

## Screens and disclosures

- Get Ian's explicit approval before adding any new screen or user-facing disclosure, including dialogs, sheets, onboarding steps, cards, and disclosure text within an existing screen.
- Show Ian the proposed UI in context before asking for approval. Include screenshots or a visual prototype of each affected state, with the exact copy and the surrounding flow. If implementation is needed to render a preview, keep it in a local build or an unmerged branch until Ian approves the design shown.
- Every added screen must conform to Lively's existing UI. Reuse the surrounding flow's components, typography, colors, spacing, and navigation. Show material changes to an approved design for approval again before merging or releasing them.

## Pull requests and tests

- Usually create a GitHub pull request when the work is done. Open it ready for review. Watch for automated review comments and CI failures.
- Evaluate test coverage for changes and fill gaps. Cover end-to-end flows and helper functions, and test behavior rather than static values.
