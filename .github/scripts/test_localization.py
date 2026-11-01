"""Tests for localization.py. Run with `python3 -m unittest discover -s .github/scripts`."""

import json
import plistlib
import tempfile
import unittest
from pathlib import Path

import localization


CATALOG = {
    "sourceLanguage": "en",
    "version": "1.0",
    "strings": {
        "": {},
        "Library": {"comment": "Tab title"},
        "AniList": {"shouldTranslate": False},
        "Removed": {"extractionState": "stale"},
        "Close": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Done"}}}},
        "Read %@ by %@": {},
        "%lld chapters": {
            "localizations": {
                "en": {
                    "variations": {
                        "plural": {
                            "one": {"stringUnit": {"state": "translated", "value": "%lld chapter"}},
                            "other": {"stringUnit": {"state": "translated", "value": "%lld chapters"}},
                        }
                    }
                }
            }
        },
    },
}


class LocalizationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        (self.root / "Ito").mkdir()
        (self.root / "Ito" / "Localizable.xcstrings").write_text(json.dumps(CATALOG), encoding="utf-8")
        localization.export(self.root)

    def tearDown(self):
        self.scratch.cleanup()

    def language(self, name, strings=None, plurals=None):
        directory = self.root / "Localization" / f"{name}.lproj"
        directory.mkdir(parents=True, exist_ok=True)
        if strings is not None:
            body = "".join(f'"{localization.escape(k)}" = "{localization.escape(v)}";\n' for k, v in strings.items())
            (directory / "Localizable.strings").write_text(body, encoding="utf-8")
        if plurals is not None:
            (directory / "Localizable.json").write_text(json.dumps(plurals, ensure_ascii=False), encoding="utf-8")
        return directory

    def installed(self, name, table):
        output = self.root / "build"
        localization.install(self.root, output)
        return plistlib.loads((output / f"{name}.lproj" / table).read_bytes())

    def test_export_lists_only_translatable_strings_with_their_english_text(self):
        strings = localization.read_strings(self.root / "Localization/en.lproj/Localizable.strings")
        self.assertEqual(strings, {"Library": "Library", "Close": "Done", "Read %@ by %@": "Read %@ by %@"})
        plurals = json.loads((self.root / "Localization/en.lproj/Localizable.json").read_text(encoding="utf-8"))
        self.assertEqual(plurals, {"%lld chapters": {"one": "%lld chapter", "other": "%lld chapters"}})
        self.assertIn("/* Tab title */", (self.root / "Localization/en.lproj/Localizable.strings").read_text(encoding="utf-8"))

    def test_untranslated_strings_fall_back_to_english_in_the_installed_table(self):
        self.language("fr", strings={"Library": "Bibliothèque"})
        table = self.installed("fr", "Localizable.strings")
        self.assertEqual(table["Library"], "Bibliothèque")
        self.assertEqual(table["Close"], "Done")
        self.assertEqual(self.installed("fr", "Localizable.stringsdict")["%lld chapters"]["value"]["other"], "%lld chapters")

    def test_unsafe_placeholders_are_replaced_by_english_and_reported(self):
        self.language("fr", strings={"Read %@ by %@": "Lu %lld par %@", "Close": "Fermer %@"})
        table = self.installed("fr", "Localizable.strings")
        self.assertEqual(table["Read %@ by %@"], "Read %@ by %@")
        self.assertEqual(table["Close"], "Done")
        problems = localization.check(self.root)
        self.assertEqual(len(problems), 2)

    def test_translations_may_reorder_or_omit_arguments(self):
        self.assertTrue(localization.compatible("Read %@ by %@", "Par %2$@, lu %1$@"))
        self.assertTrue(localization.compatible("%lld chapter", "Un chapitre"))
        self.assertFalse(localization.compatible("%lld chapter", "%@ chapitre"))
        self.assertFalse(localization.compatible("Read %@", "Lu %@ %@"))

    def test_plurals_without_an_other_form_are_completed_for_apple(self):
        # Weblate writes Polish and Russian integer forms only; their "other" is for fractions.
        self.language("pl", plurals={"%lld chapters": {"one": "%lld rozdział", "few": "%lld rozdziały", "many": "%lld rozdziałów"}})
        entry = self.installed("pl", "Localizable.stringsdict")["%lld chapters"]
        self.assertEqual(entry["value"]["few"], "%lld rozdziały")
        self.assertEqual(entry["value"]["other"], "%lld rozdziałów")
        self.assertEqual(entry["value"]["NSStringFormatValueTypeKey"], "lld")
        self.assertEqual(localization.check(self.root), [])

    def test_check_reports_a_base_file_older_than_the_catalog(self):
        catalog = dict(CATALOG, strings=dict(CATALOG["strings"], Search={}))
        (self.root / "Ito" / "Localizable.xcstrings").write_text(json.dumps(catalog), encoding="utf-8")
        self.assertEqual(len(localization.check(self.root)), 1)
        localization.export(self.root)
        self.assertEqual(localization.check(self.root), [])

    def test_keys_english_no_longer_has_are_not_installed(self):
        self.language("fr", strings={"Library": "Bibliothèque", "Gone": "Parti"})
        self.assertNotIn("Gone", self.installed("fr", "Localizable.strings"))

    def test_a_plural_with_other_arguments_chooses_its_form_by_the_number(self):
        forms = {"one": "%@ has %lld new chapter.", "other": "%@ has %lld new chapters."}
        english = localization.english_plurals({"%@ has %lld new chapters.": localization.Entry(None, forms, None)})
        self.assertEqual(english["%@ has %lld new chapters."]["one"], "%1$@ has %2$lld new chapter.")
        entry = localization.stringsdict_entry({"one": "%1$@ a %2$lld nouveau chapitre.", "other": "%@ a %lld nouveaux chapitres."}, english["%@ has %lld new chapters."]["other"])
        self.assertEqual(entry["NSStringLocalizedFormatKey"], "%2$#@value@")
        self.assertEqual(entry["value"]["NSStringFormatValueTypeKey"], "lld")

    def test_formats_the_tool_cannot_read_are_never_treated_as_safe(self):
        self.assertFalse(localization.compatible("%lld chapters", "%*d chapitres"))
        self.assertFalse(localization.compatible("%lld chapters", "%.*f chapitres"))
        self.assertTrue(localization.compatible("%lld%% done", "%lld %% fait"))

    def test_a_damaged_translation_leaves_its_table_in_english_and_is_reported(self):
        directory = self.language("fr")
        (directory / "Localizable.strings").write_text('"Library" = "Bibliothèque"\n', encoding="utf-8")
        self.assertEqual(self.installed("fr", "Localizable.strings")["Library"], "Library")
        self.assertEqual(len(localization.check(self.root)), 1)

    def test_files_as_weblate_writes_them_are_installed(self):
        directory = self.language("de")
        (directory / "Localizable.strings").write_text(
            '/* Tab title */\n"Library" = "Bibliothek \\U00fcber \\UD83D\\UDE00";\n\n"Close" = "Schließen";\n',
            encoding="utf-8",
        )
        (directory / "Localizable.json").write_text(
            '{\n    "%lld chapters": {\n        "zero": "Keine Kapitel",\n        "one": "%lld Kapitel",\n        "other": "%lld Kapitel"\n    }\n}\n',
            encoding="utf-8",
        )
        self.assertEqual(self.installed("de", "Localizable.strings")["Library"], "Bibliothek über 😀")
        self.assertEqual(self.installed("de", "Localizable.stringsdict")["%lld chapters"]["value"]["zero"], "Keine Kapitel")
        self.assertEqual(localization.check(self.root), [])

    def test_single_form_languages_written_as_plain_strings_are_installed(self):
        self.language("ja", plurals={"%lld chapters": "%lld 章"})
        self.assertEqual(self.installed("ja", "Localizable.stringsdict")["%lld chapters"]["value"]["other"], "%lld 章")

    def test_an_english_plural_form_that_shifts_arguments_is_rejected(self):
        forms = {"one": "One item in %@", "other": "%lld items in %@"}
        with self.assertRaises(localization.LocalizationError):
            localization.english_plurals({"%lld items in %@": localization.Entry(None, forms, None)})


if __name__ == "__main__":
    unittest.main()
