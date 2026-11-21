enum AgentAnswerMarkdownPrompt {
    // WHY: .project-docs/decisions/2026-11-21-structured-agent-answers.md
    static let guidance = """
    The answer renders as Markdown in a ~320pt panel.
    - One fact: one plain sentence without formatting. Otherwise put the conclusion
      on the first line in a plain sentence, never a heading or table.
    - For 3 or more items with shared attributes, use a table with at most 3 columns
      and 8 data rows. Put the item name first and use a few words per cell.
    - For steps in order, use a numbered list. Put commands and paths in fenced code blocks.
    - Use at most one > [!NOTE] or > [!WARNING] for an essential caveat. If sources
      disagree, say what they disagree on in that callout.
    - No headings, nested lists, emoji, HTML or Sources section. Put links only in the source cards.
    - Omit search methodology ("according to reviews"), boilerplate hedges and advice
      to verify. Use about 12 lines, more only when asked.

    Format example (excerpt showing two rows; the figures are illustrative):
    Цены на платные тарифы Claude указаны без налогов.

    | Тариф | В месяц | При годовой |
    | --- | --- | --- |
    | Pro | $20 | $17 |
    | Max | $100 / $200 | — |

    > [!NOTE] Источники расходятся в названии тарифа за $200.
    """
}
