# Writing style

MacCleaner uses ADS-STE100 Simplified Technical English. Use this standard for
documentation, interface text, code comments, release notes, and support text.

## Core rules

- Use one term for one item or action.
- Use short, common words.
- Use the active voice.
- Give one instruction in each sentence.
- Keep an instruction to 20 words or fewer.
- Keep a descriptive sentence to 25 words or fewer.
- Do not use contractions.
- Do not use Latin abbreviations such as `e.g.`, `i.e.`, or `etc.`.
- Put a condition before its action when the sequence is important.
- Put a warning before the action that can cause harm.
- Keep technical names unchanged.

## Interface text

Start buttons and menu items with a clear verb. Use the same verb for the same
action in all views. State the result of destructive actions before confirmation.
Do not describe a reversible move as a permanent deletion.

## Automated checks

Vale checks a useful subset of these rules. It checks sentence length,
contractions, selected word choices, Latin abbreviations, semicolons, repeated
words, and likely passive voice.

Install Vale on a development Mac:

```sh
brew install vale
```

Run the writing check:

```sh
vale README.md AGENTS.md WRITING_STYLE.md
```

Vale cannot prove full ADS-STE100 compliance. Review terminology, instructions,
warnings, interface text, and code comments manually.
