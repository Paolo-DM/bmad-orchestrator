Run /bmad-code-review for story {{STORY_KEY}}.
Story file: {{STORY_FILE_PATH}}
This is review pass {{REVIEW_PASS}} of max {{MAX_REVIEW_PASSES}}.

{{EXTRA_REVIEW_INSTRUCTIONS}}

When asked what to review, review the changes for this story.
When asked about a spec file, use {{STORY_FILE_PATH}}.
When presented with findings and asked how to handle them, choose option 1 (fix automatically).
When asked about decision-needed items, fix them using your best judgment.
Complete the entire review autonomously.

After completion, if fixes were made, commit them with:
fix: code review fixes for story {{STORY_NUMBER}} (pass {{REVIEW_PASS}})

Then output EXACTLY one of:
BMAD_RESULT:REVIEW_CLEAN
BMAD_RESULT:REVIEW_FIXED:count
