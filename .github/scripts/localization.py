#!/usr/bin/env python3
"""Keeps Ito's String Catalogs and the Weblate translation files in step.

The String Catalogs in `Ito/` hold the English source strings. Weblate cannot read
catalogs, so this tool writes their English text to `Localization/en.lproj` as plain
`.strings` and `.stringsdict` files, which Weblate uses as the base for every
language. Weblate commits translations to `Localization/<language>.lproj`, and the
app build installs them next to the catalog's English tables.

Commands:
  sync     Add strings found by a build to Localizable.xcstrings, then export.
  export   Write the English base files from the catalogs.
  check    Fail if the base files are stale or a translation is unsafe to ship.
  install  Write every translated language into a built app (Xcode build phase).
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_LANGUAGE = "en"
# Catalog in the app target -> table name Weblate edits.
CATALOGS = {
    Path("Ito/Localizable.xcstrings"): "Localizable",
    Path("Ito/InfoPlist.xcstrings"): "InfoPlist",
}
LOCALIZATION_DIR = Path("Localization")
PLURAL_FORMS = ("zero", "one", "two", "few", "many", "other")
# printf-style specifiers as Foundation formats them, plus `%%`.
SPECIFIER = re.compile(
    r"%(?:(?P<pos>\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(?P<len>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDiuUxXoOfFeEgGcCsSpaA%])"
)
PLURAL_VARIABLE = "value"


class LocalizationError(Exception):
    pass


@dataclass(frozen=True)
class Entry:
    value: str | None
    plural: dict[str, str] | None
    comment: str | None


# ---------------------------------------------------------------- catalogs


def catalog_entries(catalog: Path) -> dict[str, Entry]:
    """The translatable English strings of a catalog, keyed by their lookup key."""
    data = json.loads(catalog.read_text(encoding="utf-8"))
    if data.get("sourceLanguage") != SOURCE_LANGUAGE:
        raise LocalizationError(f"{catalog}: source language must be {SOURCE_LANGUAGE}")
    entries: dict[str, Entry] = {}
    for key, item in data.get("strings", {}).items():
        # Keys with no words (such as "%@ • %@") only arrange values; there is nothing to translate.
        wordless = not any(character.isalpha() for character in SPECIFIER.sub("", key))
        if wordless or item.get("shouldTranslate") is False or item.get("extractionState") == "stale":
            continue
        english = item.get("localizations", {}).get(SOURCE_LANGUAGE, {})
        comment = item.get("comment")
        if "substitutions" in english:
            raise LocalizationError(f"{catalog}: '{key}' uses substitutions, which the Weblate files cannot carry")
        variations = english.get("variations")
        if variations:
            if set(variations) != {"plural"}:
                raise LocalizationError(f"{catalog}: '{key}' may only vary by plural")
            forms = {form: variations["plural"][form]["stringUnit"]["value"] for form in PLURAL_FORMS if form in variations["plural"]}
            if "other" not in forms:
                raise LocalizationError(f"{catalog}: plural '{key}' needs an 'other' form")
            entries[key] = Entry(None, forms, comment)
        else:
            value = english.get("stringUnit", {}).get("value", key)
            entries[key] = Entry(value, None, comment)
    return entries


# ---------------------------------------------------------------- file formats


def escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def strings_text(entries: dict[str, Entry]) -> str:
    lines = []
    for key in sorted(entries):
        entry = entries[key]
        if entry.plural is not None:
            continue
        if entry.comment:
            lines.append(f"/* {entry.comment.replace('*/', '* /')} */")
        lines.append(f'"{escape(key)}" = "{escape(entry.value or "")}";')
        lines.append("")
    return "\n".join(lines)


def plural_argument(text: str) -> tuple[int, str, int]:
    """The position and printf type of the one integer a plural string varies by, and how
    many arguments the string reads."""
    integers: list[tuple[int, str]] = []
    positions: set[int] = set()
    implicit = 0
    for match in SPECIFIER.finditer(text):
        if match["conv"] == "%":
            continue
        if match["pos"]:
            position = int(match["pos"])
        else:
            implicit += 1
            position = implicit
        positions.add(position)
        spec = (match["len"] or "") + match["conv"]
        if canonical_kind(spec).startswith("int"):
            integers.append((position, spec))
    if len({position for position, _ in integers}) != 1:
        raise LocalizationError(f"plural string '{text}' must read exactly one whole number")
    position, spec = integers[0]
    return position, spec, len(positions)


def positional(text: str) -> str:
    """`text` with every argument numbered (`%@ has %lld` -> `%1$@ has %2$lld`)."""
    implicit = 0

    def number(match: re.Match) -> str:
        nonlocal implicit
        if match["conv"] == "%" or match["pos"]:
            return match[0]
        implicit += 1
        return f"%{implicit}${match[0][1:]}"

    return SPECIFIER.sub(number, text)


def stringsdict_entry(forms: dict[str, str], english_other: str) -> dict:
    """A plural entry, laid out as Xcode compiles a String Catalog plural: the rule reads
    the string's one whole number, by position when the string has other arguments."""
    position, spec, argument_count = plural_argument(english_other)
    rule = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": spec}
    rule.update(forms)
    format_key = f"%#@{PLURAL_VARIABLE}@" if argument_count == 1 else f"%{position}$#@{PLURAL_VARIABLE}@"
    return {"NSStringLocalizedFormatKey": format_key, PLURAL_VARIABLE: rule}


def stringsdict_data(entries: dict[str, Entry]) -> dict:
    result = {}
    for key in sorted(entries):
        forms = entries[key].plural
        if forms is None:
            continue
        _, _, argument_count = plural_argument(forms["other"])
        if argument_count > 1:
            forms = {form: positional(text) for form, text in forms.items()}
            # Each form is numbered on its own, so a form that leaves out an argument
            # before the number would shift the rest. Such forms must number arguments
            # explicitly in the catalog.
            for form, text in forms.items():
                if not compatible(forms["other"], text):
                    raise LocalizationError(f"plural '{key}': the '{form}' form must number its arguments (%1$@, %2$lld)")
        result[key] = stringsdict_entry(forms, forms["other"])
    return result


STRINGS_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}


def parse_strings(text: str, name: str) -> dict[str, str]:
    """Parses the text `.strings` format: `"key" = "value";` pairs with comments."""
    result: dict[str, str] = {}
    index = 0
    length = len(text)

    def fail(message: str) -> LocalizationError:
        line = text.count("\n", 0, index) + 1
        return LocalizationError(f"{name}:{line}: {message}")

    def skip_space() -> None:
        nonlocal index
        while index < length:
            if text[index].isspace():
                index += 1
            elif text.startswith("/*", index):
                end = text.find("*/", index + 2)
                if end < 0:
                    raise fail("unterminated comment")
                index = end + 2
            elif text.startswith("//", index):
                end = text.find("\n", index)
                index = length if end < 0 else end + 1
            else:
                return

    def quoted() -> str:
        nonlocal index
        if index >= length or text[index] != '"':
            raise fail("expected a quoted string")
        index += 1
        parts: list[str] = []
        while True:
            if index >= length:
                raise fail("unterminated string")
            character = text[index]
            if character == '"':
                index += 1
                return "".join(parts)
            if character == "\\":
                escape_character = text[index + 1:index + 2]
                if escape_character in ("U", "u"):
                    digits = text[index + 2:index + 6]
                    if not re.fullmatch(r"[0-9A-Fa-f]{4}", digits):
                        raise fail("bad \\U escape")
                    parts.append(chr(int(digits, 16)))
                    index += 6
                    continue
                if escape_character not in STRINGS_ESCAPES:
                    raise fail(f"unknown escape \\{escape_character}")
                parts.append(STRINGS_ESCAPES[escape_character])
                index += 2
                continue
            parts.append(character)
            index += 1

    skip_space()
    while index < length:
        key = quoted()
        skip_space()
        if not text.startswith("=", index):
            raise fail("expected '='")
        index += 1
        skip_space()
        value = quoted()
        skip_space()
        if not text.startswith(";", index):
            raise fail("expected ';'")
        index += 1
        result[key] = value
        skip_space()
    # Surrogate pairs written as two \U escapes.
    try:
        return {
            k.encode("utf-16", "surrogatepass").decode("utf-16"): v.encode("utf-16", "surrogatepass").decode("utf-16")
            for k, v in result.items()
        }
    except UnicodeError:
        raise LocalizationError(f"{name}: contains an unpaired \\U surrogate escape") from None


def read_strings(path: Path) -> dict[str, str]:
    """Reads a `.strings` file written as text (Weblate) or as a property list."""
    raw = path.read_bytes()
    if raw.startswith(b"bplist") or raw.lstrip().startswith(b"<?xml"):
        try:
            data = plistlib.loads(raw)
        except Exception:
            raise LocalizationError(f"{path}: not a valid strings file") from None
        if not isinstance(data, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data.items()):
            raise LocalizationError(f"{path}: expected string keys and values")
        return data
    for encoding in ("utf-8-sig", "utf-16"):
        try:
            text = raw.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:
        raise LocalizationError(f"{path}: not UTF-8 or UTF-16 text")
    return parse_strings(text, str(path))


def read_stringsdict(path: Path) -> dict:
    try:
        data = plistlib.loads(path.read_bytes())
    except Exception:
        raise LocalizationError(f"{path}: not a valid stringsdict file") from None
    if not isinstance(data, dict):
        raise LocalizationError(f"{path}: expected a dictionary")
    return data


# ---------------------------------------------------------------- placeholders


def specifiers(text: str) -> dict[int, str]:
    """Argument position -> conversion, in the form Foundation would consume them.

    Raises for any `%` this tool does not understand (such as `%*d`, which reads an
    extra width argument), so such text is never treated as safe.
    """
    result: dict[int, str] = {}
    implicit = 0
    consumed = 0
    for match in SPECIFIER.finditer(text):
        if "%" in text[consumed:match.start()]:
            raise LocalizationError(f"unsupported format in '{text}'")
        consumed = match.end()
        conv = match["conv"]
        if conv == "%":
            continue
        if match["pos"]:
            position = int(match["pos"])
        else:
            implicit += 1
            position = implicit
        kind = canonical_kind((match["len"] or "") + conv)
        if result.get(position, kind) != kind:
            raise LocalizationError(f"argument {position} is used with two different types")
        result[position] = kind
    if "%" in text[consumed:]:
        raise LocalizationError(f"unsupported format in '{text}'")
    return result


def canonical_kind(spec: str) -> str:
    conv = spec[-1]
    length = spec[:-1]
    if conv in "@":
        return "object"
    if conv in "sS":
        return "cstring"
    if conv in "cC":
        return "char"
    if conv in "fFeEgGaA":
        return "double"
    if conv == "p":
        return "pointer"
    width = "64" if length in ("ll", "q", "l", "z", "t", "j") else "32"
    return f"int{width}"


def compatible(english: str, translation: str) -> bool:
    """A translation is safe if it reads the same arguments with the same types.

    A translation may leave out an argument (for example a count in a singular form)
    but must never read one English does not pass, or read one with another type.
    """
    try:
        source = specifiers(english)
        target = specifiers(translation)
    except LocalizationError:
        return False
    return all(source.get(position) == kind for position, kind in target.items())


def plural_forms(entry: object) -> dict[str, str] | None:
    """The forms of a single-variable plural stringsdict entry, or None if it is not one."""
    if not isinstance(entry, dict):
        return None
    format_key = entry.get("NSStringLocalizedFormatKey")
    if not isinstance(format_key, str) or not re.fullmatch(rf"%(\d+\$)?#@{PLURAL_VARIABLE}@", format_key):
        return None
    rule = entry.get(PLURAL_VARIABLE)
    if not isinstance(rule, dict) or rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType":
        return None
    forms = {form: rule[form] for form in PLURAL_FORMS if isinstance(rule.get(form), str)}
    return forms if "other" in forms else None


# ---------------------------------------------------------------- commands


def base_files(root: Path) -> dict[Path, bytes]:
    """The English Weblate base files the catalogs produce, by repository path."""
    files: dict[Path, bytes] = {}
    base = LOCALIZATION_DIR / f"{SOURCE_LANGUAGE}.lproj"
    for catalog, table in CATALOGS.items():
        path = root / catalog
        if not path.exists():
            continue
        entries = catalog_entries(path)
        files[base / f"{table}.strings"] = strings_text(entries).encode("utf-8")
        plurals = stringsdict_data(entries)
        if plurals:
            files[base / f"{table}.stringsdict"] = plistlib.dumps(plurals, sort_keys=True)
    return files


def export(root: Path) -> None:
    files = base_files(root)
    base = root / LOCALIZATION_DIR / f"{SOURCE_LANGUAGE}.lproj"
    base.mkdir(parents=True, exist_ok=True)
    for stale in base.iterdir():
        if stale.relative_to(root) not in files:
            stale.unlink()
    for path, content in files.items():
        (root / path).write_bytes(content)


def languages(root: Path) -> list[Path]:
    directory = root / LOCALIZATION_DIR
    if not directory.is_dir():
        return []
    return sorted(
        path for path in directory.glob("*.lproj")
        if path.is_dir() and path.stem != SOURCE_LANGUAGE
    )


def merged_tables(root: Path, language: Path, problems: list[str]) -> dict[str, dict]:
    """Every table of `language`, completed with English where it has no usable translation.

    Translations that would read arguments English does not pass are left out (and
    reported), so a mistake on Weblate shows English instead of crashing the app.
    """
    base = root / LOCALIZATION_DIR / f"{SOURCE_LANGUAGE}.lproj"
    tables: dict[str, dict] = {}
    for table in CATALOGS.values():
        english_path = base / f"{table}.strings"
        if english_path.exists():
            english = read_strings(english_path)
            merged = dict(english)
            translated_path = language / f"{table}.strings"
            if translated_path.exists():
                for key, value in translations(translated_path, read_strings, root, problems).items():
                    if key not in english or not value:
                        continue
                    if compatible(english[key], value):
                        merged[key] = value
                    else:
                        problems.append(f"{translated_path.relative_to(root)}: '{key}' has placeholders that do not match English")
            tables[f"{table}.strings"] = merged
        english_dict_path = base / f"{table}.stringsdict"
        if english_dict_path.exists():
            english_dict = read_stringsdict(english_dict_path)
            merged_dict = dict(english_dict)
            translated_dict_path = language / f"{table}.stringsdict"
            if translated_dict_path.exists():
                for key, entry in translations(translated_dict_path, read_stringsdict, root, problems).items():
                    source = plural_forms(english_dict.get(key))
                    forms = plural_forms(entry)
                    if source is None or forms is None:
                        if key in english_dict:
                            problems.append(f"{translated_dict_path.relative_to(root)}: '{key}' is not a plural entry")
                        continue
                    if all(compatible(source["other"], text) for text in forms.values()):
                        merged_dict[key] = stringsdict_entry(forms, source["other"])
                    else:
                        problems.append(f"{translated_dict_path.relative_to(root)}: '{key}' has placeholders that do not match English")
            tables[f"{table}.stringsdict"] = merged_dict
    return tables


def translations(path: Path, reader, root: Path, problems: list[str]) -> dict:
    """The entries of a translated file, or none (with a reported problem) if it cannot be
    read, so one damaged file leaves that table in English instead of failing the build."""
    try:
        return reader(path)
    except (LocalizationError, UnicodeError, ValueError) as error:
        problems.append(f"{path.relative_to(root)}: {error}")
        return {}


def check(root: Path) -> list[str]:
    problems: list[str] = []
    files = base_files(root)
    for path, content in files.items():
        current = root / path
        if not current.exists() or current.read_bytes() != content:
            problems.append(f"{path} is out of date; run `.github/scripts/localization.py export`")
    base = root / LOCALIZATION_DIR / f"{SOURCE_LANGUAGE}.lproj"
    if base.is_dir():
        for path in base.iterdir():
            if path.relative_to(root) not in files:
                problems.append(f"{path.relative_to(root)} has no catalog; run `.github/scripts/localization.py export`")
    for language in languages(root):
        try:
            merged_tables(root, language, problems)
        except LocalizationError as error:
            problems.append(str(error))
    return problems


def install(root: Path, output: Path) -> None:
    for language in languages(root):
        problems: list[str] = []
        tables = merged_tables(root, language, problems)
        for problem in problems:
            print(f"warning: {problem}; English is used instead", file=sys.stderr)
        destination = output / language.name
        destination.mkdir(parents=True, exist_ok=True)
        for name, table in tables.items():
            (destination / name).write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_BINARY, sort_keys=True))


def app_stringsdata(derived_data: Path) -> list[Path]:
    """The `.stringsdata` the app target's last build wrote (not its test targets')."""
    found = []
    for path in (derived_data / "Build" / "Intermediates.noindex").rglob("*.stringsdata"):
        parts = path.parts
        # …/Ito.build/<configuration>-<platform>/Ito.build/…: project, then target.
        if any(parts[i] == "Ito.build" and parts[i + 2] == "Ito.build" for i in range(len(parts) - 2)):
            found.append(path)
    return sorted(found)


def catalog_content(data: bytes) -> dict:
    """What a catalog says, independent of how a given Xcode version lays out the file."""
    strings = json.loads(data).get("strings", {})
    return {key: json.dumps(value, sort_keys=True) for key, value in strings.items()}


def sync(root: Path, derived_data: Path, check_only: bool) -> bool:
    """Adds the strings a build found to the catalog. With `check_only`, only reports
    whether the committed catalog already has them; returns whether it did."""
    stringsdata = app_stringsdata(derived_data)
    if not stringsdata:
        raise LocalizationError(f"no .stringsdata under {derived_data}; build the Ito scheme with that derived data path first")
    catalog = root / "Ito" / "Localizable.xcstrings"
    with tempfile.TemporaryDirectory() as scratch:
        target = Path(scratch) / catalog.name
        target.write_bytes(catalog.read_bytes())
        command = ["xcrun", "xcstringstool", "sync", str(target)]
        for path in stringsdata:
            command += ["--stringsdata", str(path)]
        subprocess.run(command, check=True)
        synced = target.read_bytes()
    if check_only:
        return catalog_content(synced) == catalog_content(catalog.read_bytes())
    catalog.write_bytes(synced)
    export(root)
    return True


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("export")
    commands.add_parser("check")
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--output", type=Path, required=True, help="the app's resources directory")
    sync_parser = commands.add_parser("sync")
    sync_parser.add_argument("--derived-data", type=Path, required=True)
    sync_parser.add_argument("--check", action="store_true", help="only report whether the catalog is current")
    arguments = parser.parse_args(argv)
    root = arguments.root.resolve()
    try:
        if arguments.command == "export":
            export(root)
        elif arguments.command == "check":
            problems = check(root)
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            return 1 if problems else 0
        elif arguments.command == "install":
            install(root, arguments.output)
        elif arguments.command == "sync":
            if not sync(root, arguments.derived_data, arguments.check):
                print(
                    "error: Ito/Localizable.xcstrings does not match the strings the app uses; "
                    "run `.github/scripts/localization.py sync --derived-data <path>` after a build",
                    file=sys.stderr,
                )
                return 1
    except LocalizationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
