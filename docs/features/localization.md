# Languages

Trellis shows its own text in English, European Portuguese, French or Spanish. That covers the menus, Settings, the sidebars, sheets, alerts, tooltips, notifications, the welcome tour and the labels VoiceOver reads.

Some text is never translated:

- what your shells and programs print, and what you type;
- names you or a file chose: tabs, spaces, projects, hosts, tasks, themes, agents;
- names Trellis saves for you, such as the first tab's title;
- the `trellis` command, the automation API and MCP, including error codes and their messages, so scripts behave the same in every language;
- diagnostics exports, which support reads in English.

All requirements here are P2.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-LN01 | Follow the Mac's language by default. **Settings → Appearance → Language** offers System, English, Português, Français and Español. System takes the first of the Mac's preferred languages that Trellis has, matching on the language alone, so Brazilian Portuguese gets European Portuguese and Canadian French gets French. With none of them in the list, Trellis is in English. | `LocalizationTests` resolves `pt-BR`, `fr-CA`, `es-419` and `de` then `es`, and falls back to English for `de` alone. With the Mac in French and Language on System, the menus are in French. |
| FR-LN02 | Each language in the picker is listed under its own name, whatever language the app is showing, so a reader can always find theirs. | In every language the picker reads English, Português, Français, Español. |
| FR-LN03 | A language change applies with the rest of the Appearance pane and needs no relaunch: the main window, Settings, the open panels and the menu bar change together. The choice is saved with the appearance settings. Settings saved by an older build, or naming a language this build doesn't have, follow the system. | Choose Français and press Apply: the menu bar, sidebar and Settings are in French right away, and still are after a relaunch. A workspace file without `language` loads as System. |
| FR-LN04 | English is the source. Every piece of translated text is looked up by its English wording, so text without a translation appears in English and never as a blank or a key name. Every table has an entry for each piece of text in the source, no entries the source doesn't use, and the same placeholders as the English. | `LocalizationTests` compares each table with the text found in `Sources/`, in both directions, and compares placeholders. A table that can't be read leaves the app in English. |
| FR-LN05 | `--language en\|pt-PT\|fr\|es` picks the language for one launch without saving it, like `--renderer`. An unknown value is ignored. | `swift run Trellis --fixture --language fr` opens in French, and the next launch without the argument is back to the saved choice. |
| FR-LN06 | Text with a count reads correctly for one and for many in every language. | `LocalizationTests` checks that singular and plural wordings both exist for each counted phrase. |

## Notes

Translations ship inside the app as one JSON file per language (`Sources/TrellisCore/Resources/Localizations/`). To add or change wording, edit the English in the source and the matching entry in each file; the tests fail until all three have it.

Numbers, dates and times keep the Mac's own formats.

The first translations were machine-written and reviewed against the English. A read-through by native speakers and a layout check of every window in each language are **pending**, as is a VoiceOver pass.
