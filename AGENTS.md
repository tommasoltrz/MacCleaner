# Project instructions

## Writing

Use ADS-STE100 Simplified Technical English for all new writing.

- Use the same term for the same item or action.
- Use approved, common words when possible.
- Use the active voice.
- Give one instruction in each sentence.
- Keep instructions to 20 words or fewer.
- Keep descriptive sentences to 25 words or fewer.
- Do not use contractions or Latin abbreviations.
- Put conditions before the action when the sequence is important.
- Write warnings before the action that can cause harm.
- Do not change technical names, API names, file paths, or quoted interface text.

Apply these rules to documentation, interface text, code comments, release notes,
and messages for users.

Run `vale README.md AGENTS.md WRITING_STYLE.md` after you change tracked
documentation. Review interface text and code comments manually because Vale does
not check Swift string literals.

The file `design/README.md` contains the archived handoff. Do not revise it during
a general writing pass.
