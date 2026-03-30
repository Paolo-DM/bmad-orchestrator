Run /bmad-dev-story for story {{STORY_KEY}}.
Story file: {{STORY_FILE_PATH}}

{{EXTRA_DEV_INSTRUCTIONS}}

Complete ALL tasks and subtasks in the story file. Run ALL tests and ensure they pass.
When presented with interactive checkpoints, choose to continue.
Do not stop for user input — complete the entire workflow autonomously.
If you encounter a HALT condition, output: BMAD_RESULT:HALT:reason

After successful completion, commit your work with this exact message:
feat: story {{STORY_NUMBER}} — {{STORY_NAME_PRETTY}}

Then output: BMAD_RESULT:DEV_COMPLETE
If tests fail after implementation, output: BMAD_RESULT:DEV_TESTS_FAILED:details
