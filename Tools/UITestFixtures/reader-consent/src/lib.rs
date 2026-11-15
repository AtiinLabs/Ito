//! Deterministic local source for the reader consent UI tests.
//!
//! Every response is built in memory. The source makes no network requests, reads no settings,
//! needs no login and calls no host service, so the UI tests see the same catalog on every run.

use ito_rs::{
    Error, Result,
    models::{
        CatalogCompleteness, CatalogScope, Chapter, ChapterCatalog, ContentKind, FilterItem,
        Listing, MediaEntry, MediaKind, MediaPageResult, Page, PageContent, Scanlator,
        manga::{self, Manga},
        novel::{self, Novel},
    },
    provider::SourceProvider,
};

const MANGA_KEY: &str = "reader-fixture-manga";
const NOVEL_KEY: &str = "reader-fixture-novel";

/// The catalog both series return: every eligible upload is listed and the list is complete.
const CHAPTER_CATALOG: ChapterCatalog = ChapterCatalog {
    scope: CatalogScope::AllEligible,
    completeness: CatalogCompleteness::Complete,
};

/// The two uploads both series carry, in reading order.
const CHAPTERS: [ChapterSpec; 2] = [
    ChapterSpec {
        key: "chapter-a",
        title: "Chapter 1",
        number: 1.0,
        group_id: "group-a",
        group_name: "Group A",
        logical_unit_id: "unit-1",
        reading_order: 1,
    },
    ChapterSpec {
        key: "chapter-b",
        title: "Chapter 2",
        number: 2.0,
        group_id: "group-b",
        group_name: "Group B",
        logical_unit_id: "unit-2",
        reading_order: 2,
    },
];

struct ChapterSpec {
    key: &'static str,
    title: &'static str,
    number: f64,
    group_id: &'static str,
    group_name: &'static str,
    logical_unit_id: &'static str,
    reading_order: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Series {
    Manga,
    Novel,
}

impl Series {
    const ALL: [Series; 2] = [Series::Manga, Series::Novel];

    fn key(self) -> &'static str {
        match self {
            Series::Manga => MANGA_KEY,
            Series::Novel => NOVEL_KEY,
        }
    }

    fn title(self) -> &'static str {
        match self {
            Series::Manga => "Reader Consent Manga",
            Series::Novel => "Reader Consent Novel",
        }
    }

    /// Manga chapters open the page reader; novel chapters open the text reader.
    fn content_kind(self) -> ContentKind {
        match self {
            Series::Manga => ContentKind::Images,
            Series::Novel => ContentKind::Text,
        }
    }

    /// The text of each page of one chapter, in page order.
    fn page_texts(self, chapter_key: &str) -> Option<&'static [&'static str]> {
        match (self, chapter_key) {
            (Series::Manga, "chapter-a") => Some(&[
                "Reader fixture manga A page 1",
                "Reader fixture manga A page 2",
            ]),
            (Series::Manga, "chapter-b") => Some(&["Reader fixture manga B"]),
            (Series::Novel, "chapter-a") => Some(&["Reader fixture novel A"]),
            (Series::Novel, "chapter-b") => Some(&["Reader fixture novel B"]),
            _ => None,
        }
    }

    fn chapters(self) -> Vec<Chapter> {
        CHAPTERS
            .iter()
            .map(|spec| Chapter {
                title: Some(spec.title.into()),
                chapter: Some(spec.number),
                scanlator: Some(Scanlator::with_id(spec.group_id, spec.group_name)),
                lang: Some("en".into()),
                paywalled: Some(false),
                logical_unit_id: Some(spec.logical_unit_id.into()),
                reading_order: Some(spec.reading_order),
                ..Chapter::new(spec.key, self.content_kind())
            })
            .collect()
    }

    fn entry(self) -> MediaEntry {
        let chapters = Some(self.chapters());
        let catalog = Some(CHAPTER_CATALOG);
        match self {
            Series::Manga => MediaEntry::Manga(Manga {
                key: self.key().into(),
                title: self.title().into(),
                authors: None,
                artist: None,
                description: Some("Local fixture for the reader consent UI tests.".into()),
                tags: None,
                cover: None,
                url: None,
                status: manga::Status::Ongoing,
                content_rating: manga::ContentRating::Safe,
                nsfw: 0,
                viewer: manga::Viewer::Default,
                chapters,
                catalog,
            }),
            Series::Novel => MediaEntry::Novel(Novel {
                key: self.key().into(),
                title: self.title().into(),
                authors: None,
                artist: None,
                description: Some("Local fixture for the reader consent UI tests.".into()),
                tags: None,
                cover: None,
                url: None,
                status: novel::Status::Ongoing,
                content_rating: novel::ContentRating::Safe,
                nsfw: 0,
                chapters,
                catalog,
            }),
        }
    }
}

fn series_of(entry: &MediaEntry) -> Result<Series> {
    match entry {
        MediaEntry::Manga(manga) if manga.key == MANGA_KEY => Ok(Series::Manga),
        MediaEntry::Novel(novel) if novel.key == NOVEL_KEY => Ok(Series::Novel),
        MediaEntry::Anime(_) => Err(Error::Unsupported),
        _ => Err(Error::NotFound("unknown fixture media key".into())),
    }
}

pub struct ReaderConsentFixture;

impl SourceProvider for ReaderConsentFixture {
    const KINDS: &'static [MediaKind] = &[MediaKind::Manga, MediaKind::Novel];

    fn get_listing(_: Listing, page: i32) -> Result<MediaPageResult> {
        Self::search("", page, None, Vec::new())
    }

    fn search(
        query: &str,
        page: i32,
        kind: Option<MediaKind>,
        filters: Vec<FilterItem>,
    ) -> Result<MediaPageResult> {
        // This source declares no search controls, so any filter is a request it cannot serve.
        if !filters.is_empty() {
            return Err(Error::Unsupported);
        }
        let wanted: &[Series] = match kind {
            None => &Series::ALL,
            Some(MediaKind::Manga) => &[Series::Manga],
            Some(MediaKind::Novel) => &[Series::Novel],
            Some(MediaKind::Anime) => return Err(Error::Unsupported),
        };
        // The fixture is one page long; page numbers are one-based.
        if page > 1 {
            return Ok(MediaPageResult {
                entries: Vec::new(),
                has_next_page: false,
            });
        }
        let query = query.to_lowercase();
        let entries = wanted
            .iter()
            .filter(|series| series.title().to_lowercase().contains(&query))
            .map(|series| series.entry())
            .collect();
        Ok(MediaPageResult {
            entries,
            has_next_page: false,
        })
    }

    fn get_media_update(entry: MediaEntry, _: bool, _: bool) -> Result<MediaEntry> {
        Ok(series_of(&entry)?.entry())
    }

    fn get_chapter_pages(entry: MediaEntry, chapter: Chapter) -> Result<Vec<Page>> {
        let series = series_of(&entry)?;
        let texts = series
            .page_texts(&chapter.key)
            .ok_or_else(|| Error::NotFound("unknown fixture chapter key".into()))?;
        Ok(texts
            .iter()
            .zip(0_i32..)
            .map(|(text, index)| Page {
                index,
                content: PageContent::Text((*text).into()),
                has_description: false,
                description: None,
                headers: None,
            })
            .collect())
    }
}

ito_rs::export_plugin!(ReaderConsentFixture);

#[cfg(test)]
mod tests {
    use super::*;
    use ito_rs::{catalog, models::FilterValue};

    fn listing() -> Listing {
        Listing {
            id: "latest".into(),
            name: "Latest".into(),
            kind: 0,
        }
    }

    fn entries_of(page: MediaPageResult) -> Vec<MediaEntry> {
        assert!(!page.has_next_page, "fixture has a single page");
        page.entries
    }

    fn chapters_of(entry: &MediaEntry) -> &[Chapter] {
        match entry {
            MediaEntry::Manga(manga) => manga.chapters.as_deref().expect("chapters"),
            MediaEntry::Novel(novel) => novel.chapters.as_deref().expect("chapters"),
            MediaEntry::Anime(_) => panic!("fixture serves no anime"),
        }
    }

    fn texts_of(pages: &[Page]) -> Vec<&str> {
        pages
            .iter()
            .map(|page| match &page.content {
                PageContent::Text(text) => text.as_str(),
                other => panic!("expected a text page, got {other:?}"),
            })
            .collect()
    }

    fn keys_of(entries: &[MediaEntry]) -> Vec<&str> {
        entries.iter().map(MediaEntry::key).collect()
    }

    #[test]
    fn listing_serves_both_series_with_two_ordered_chapters() {
        let entries = entries_of(ReaderConsentFixture::get_listing(listing(), 1).expect("listing"));
        let kinds: Vec<MediaKind> = entries.iter().map(MediaEntry::kind).collect();
        assert_eq!(kinds, [MediaKind::Manga, MediaKind::Novel]);
        for entry in &entries {
            assert!(
                catalog::validate_entry(entry).is_ok(),
                "{} violates the catalog contract",
                entry.key()
            );
            let chapters = chapters_of(entry);
            let keys: Vec<&str> = chapters
                .iter()
                .map(|chapter| chapter.key.as_str())
                .collect();
            assert_eq!(keys, ["chapter-a", "chapter-b"], "{}", entry.key());
            let groups: Vec<(&str, &str)> = chapters
                .iter()
                .map(|chapter| {
                    let scanlator = chapter.scanlator.as_ref().expect("scanlator");
                    (
                        scanlator.id.as_deref().expect("scanlator id"),
                        scanlator.name.as_str(),
                    )
                })
                .collect();
            assert_eq!(
                groups,
                [("group-a", "Group A"), ("group-b", "Group B")],
                "{}",
                entry.key()
            );
            let units: Vec<&str> = chapters
                .iter()
                .map(|chapter| chapter.logical_unit_id.as_deref().expect("unit"))
                .collect();
            assert_eq!(units, ["unit-1", "unit-2"], "{}", entry.key());
            assert!(
                chapters
                    .iter()
                    .all(|chapter| chapter.paywalled == Some(false))
            );
        }
    }

    #[test]
    fn search_filters_by_kind_and_query() {
        let search = |query: &str, kind| {
            ReaderConsentFixture::search(query, 1, kind, Vec::new()).expect("search")
        };
        let all = search("", None);
        assert_eq!(keys_of(&all.entries), [MANGA_KEY, NOVEL_KEY]);
        let manga = search("", Some(MediaKind::Manga));
        assert_eq!(keys_of(&manga.entries), [MANGA_KEY]);
        let novel = search("", Some(MediaKind::Novel));
        assert_eq!(keys_of(&novel.entries), [NOVEL_KEY]);
        let matched = search("NOVEL", None);
        assert_eq!(
            keys_of(&matched.entries),
            [NOVEL_KEY],
            "query is case-insensitive"
        );
        assert!(search("absent", None).entries.is_empty());
        assert!(matches!(
            ReaderConsentFixture::search("", 1, Some(MediaKind::Anime), Vec::new()),
            Err(Error::Unsupported)
        ));
        let second = ReaderConsentFixture::search("", 2, None, Vec::new()).expect("page two");
        assert!(second.entries.is_empty() && !second.has_next_page);
        let filter = FilterItem {
            type_name: "select".into(),
            name: "sort".into(),
            value: FilterValue::String("title".into()),
        };
        assert!(matches!(
            ReaderConsentFixture::search("", 1, None, vec![filter]),
            Err(Error::Unsupported)
        ));
    }

    #[test]
    fn media_update_returns_the_same_catalog_as_listing() {
        for entry in entries_of(ReaderConsentFixture::get_listing(listing(), 1).expect("listing")) {
            let updated = ReaderConsentFixture::get_media_update(entry.clone(), true, true)
                .expect("media update");
            assert_eq!(
                format!("{updated:?}"),
                format!("{entry:?}"),
                "{}",
                entry.key()
            );
        }
        let mut unknown = Series::Novel.entry();
        if let MediaEntry::Novel(novel) = &mut unknown {
            novel.key = "missing".into();
        }
        assert!(matches!(
            ReaderConsentFixture::get_media_update(unknown, false, false),
            Err(Error::NotFound(_))
        ));
    }

    #[test]
    fn chapter_pages_carry_the_fixture_sentinels() {
        let manga = Series::Manga.entry();
        let novel = Series::Novel.entry();
        let chapter = |entry: &MediaEntry, index: usize| chapters_of(entry)[index].clone();

        let manga_a = ReaderConsentFixture::get_chapter_pages(manga.clone(), chapter(&manga, 0))
            .expect("manga A");
        assert_eq!(
            texts_of(&manga_a),
            [
                "Reader fixture manga A page 1",
                "Reader fixture manga A page 2"
            ]
        );
        assert_eq!(
            manga_a.iter().map(|page| page.index).collect::<Vec<_>>(),
            [0, 1]
        );
        let manga_b = ReaderConsentFixture::get_chapter_pages(manga.clone(), chapter(&manga, 1))
            .expect("manga B");
        assert_eq!(texts_of(&manga_b), ["Reader fixture manga B"]);

        let novel_a = ReaderConsentFixture::get_chapter_pages(novel.clone(), chapter(&novel, 0))
            .expect("novel A");
        assert_eq!(texts_of(&novel_a), ["Reader fixture novel A"]);
        let novel_b = ReaderConsentFixture::get_chapter_pages(novel.clone(), chapter(&novel, 1))
            .expect("novel B");
        assert_eq!(texts_of(&novel_b), ["Reader fixture novel B"]);

        let mut unknown = chapter(&manga, 0);
        unknown.key = "chapter-z".into();
        assert!(matches!(
            ReaderConsentFixture::get_chapter_pages(manga, unknown),
            Err(Error::NotFound(_))
        ));
    }

    #[test]
    fn chapter_kinds_follow_the_series() {
        for chapter in chapters_of(&Series::Manga.entry()) {
            assert_eq!(chapter.kind, ContentKind::Images);
        }
        for chapter in chapters_of(&Series::Novel.entry()) {
            assert_eq!(chapter.kind, ContentKind::Text);
        }
    }
}
