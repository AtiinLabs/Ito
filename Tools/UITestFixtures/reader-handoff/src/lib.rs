//! Deterministic local source for the image/text reader handoff UI tests.
//!
//! One manga whose chapters alternate between images and text, so the reader has to move between the page
//! reader and the text reader. Every response is built in memory: the images are served through the
//! plugin's own image handler, and chapter 4 is text that always fails to load. The source makes no network
//! requests, reads no settings and needs no login.

use ito_rs::{
    Error, Result,
    models::{
        CatalogCompleteness, CatalogScope, Chapter, ChapterCatalog, ContentKind, FilterItem,
        Listing, MediaEntry, MediaKind, MediaPageResult, Page, PageContent, Scanlator,
        manga::{self, Manga},
    },
    provider::SourceProvider,
};

const PLUGIN_ID: &str = "moe.itoapp.test.reader-handoff-fixture";
const MANGA_KEY: &str = "reader-handoff-manga";
const MANGA_TITLE: &str = "Reader Handoff Manga";

/// One image every image page shows; the host asks for it by its locator, and the plugin answers with bytes.
const PAGE_PNG: &[u8] = include_bytes!("../page.png");

const CHAPTER_CATALOG: ChapterCatalog = ChapterCatalog {
    scope: CatalogScope::AllEligible,
    completeness: CatalogCompleteness::Complete,
};

struct ChapterSpec {
    key: &'static str,
    title: &'static str,
    number: f64,
    kind: ContentKind,
    /// The body of each text page, or the number of image pages.
    body: Body,
}

enum Body {
    Text(&'static [&'static str]),
    Images(u8),
    /// The chapter exists in the catalog but its pages cannot be loaded.
    Fails,
}

/// Images, text, images, then a text chapter that fails: every neighbor is the other reader's.
const CHAPTERS: [ChapterSpec; 4] = [
    ChapterSpec {
        key: "ch1",
        title: "Chapter 1",
        number: 1.0,
        kind: ContentKind::Images,
        body: Body::Images(2),
    },
    ChapterSpec {
        key: "ch2",
        title: "Chapter 2",
        number: 2.0,
        kind: ContentKind::Text,
        body: Body::Text(&[
            "Handoff text chapter two first paragraph.",
            "Handoff text chapter two second paragraph.",
        ]),
    },
    ChapterSpec {
        key: "ch3",
        title: "Chapter 3",
        number: 3.0,
        kind: ContentKind::Images,
        body: Body::Images(2),
    },
    ChapterSpec {
        key: "ch4",
        title: "Chapter 4",
        number: 4.0,
        kind: ContentKind::Text,
        body: Body::Fails,
    },
];

fn locator(chapter_key: &str, index: u8) -> String {
    format!("ito://{PLUGIN_ID}/{chapter_key}-{index}.png")
}

fn chapters() -> Vec<Chapter> {
    CHAPTERS
        .iter()
        .zip(1_i64..)
        .map(|(spec, order)| Chapter {
            title: Some(spec.title.into()),
            chapter: Some(spec.number),
            scanlator: Some(Scanlator::with_id("group-a", "Group A")),
            lang: Some("en".into()),
            paywalled: Some(false),
            logical_unit_id: Some(format!("unit-{order}")),
            reading_order: Some(order),
            ..Chapter::new(spec.key, spec.kind)
        })
        .collect()
}

fn entry() -> MediaEntry {
    MediaEntry::Manga(Manga {
        key: MANGA_KEY.into(),
        title: MANGA_TITLE.into(),
        authors: None,
        artist: None,
        description: Some("Local fixture for the reader handoff UI tests.".into()),
        tags: None,
        cover: None,
        url: None,
        status: manga::Status::Ongoing,
        content_rating: manga::ContentRating::Safe,
        nsfw: 0,
        viewer: manga::Viewer::Default,
        chapters: Some(chapters()),
        catalog: Some(CHAPTER_CATALOG),
    })
}

pub struct ReaderHandoffFixture;

impl SourceProvider for ReaderHandoffFixture {
    const KINDS: &'static [MediaKind] = &[MediaKind::Manga];

    fn get_listing(_: Listing, page: i32) -> Result<MediaPageResult> {
        Self::search("", page, None, Vec::new())
    }

    fn search(
        query: &str,
        page: i32,
        kind: Option<MediaKind>,
        filters: Vec<FilterItem>,
    ) -> Result<MediaPageResult> {
        if !filters.is_empty() {
            return Err(Error::Unsupported);
        }
        if matches!(kind, Some(MediaKind::Novel | MediaKind::Anime)) || page > 1 {
            return Ok(MediaPageResult {
                entries: Vec::new(),
                has_next_page: false,
            });
        }
        let entries = if MANGA_TITLE.to_lowercase().contains(&query.to_lowercase()) {
            vec![entry()]
        } else {
            Vec::new()
        };
        Ok(MediaPageResult {
            entries,
            has_next_page: false,
        })
    }

    fn get_media_update(entry_in: MediaEntry, _: bool, _: bool) -> Result<MediaEntry> {
        match entry_in {
            MediaEntry::Manga(manga) if manga.key == MANGA_KEY => Ok(entry()),
            MediaEntry::Anime(_) => Err(Error::Unsupported),
            _ => Err(Error::NotFound("unknown fixture media key".into())),
        }
    }

    fn get_chapter_pages(entry_in: MediaEntry, chapter: Chapter) -> Result<Vec<Page>> {
        if entry_in.key() != MANGA_KEY {
            return Err(Error::NotFound("unknown fixture media key".into()));
        }
        let spec = CHAPTERS
            .iter()
            .find(|spec| spec.key == chapter.key)
            .ok_or_else(|| Error::NotFound("unknown fixture chapter key".into()))?;
        let contents: Vec<PageContent> = match &spec.body {
            Body::Text(paragraphs) => paragraphs
                .iter()
                .map(|text| PageContent::Text((*text).into()))
                .collect(),
            Body::Images(count) => (1..=*count)
                .map(|index| PageContent::Url(locator(spec.key, index)))
                .collect(),
            Body::Fails => return Err(Error::Server("fixture chapter cannot be loaded".into())),
        };
        Ok(contents
            .into_iter()
            .zip(0_i32..)
            .map(|(content, index)| Page {
                index,
                content,
                has_description: false,
                description: None,
                headers: None,
            })
            .collect())
    }

    fn handle_image(url: &str) -> Result<Vec<u8>> {
        if url.ends_with(".png") {
            Ok(PAGE_PNG.to_vec())
        } else {
            Err(Error::NotFound("unknown fixture image".into()))
        }
    }
}

ito_rs::export_plugin!(ReaderHandoffFixture);

#[cfg(test)]
mod tests {
    use super::*;
    use ito_rs::catalog;

    #[test]
    fn the_catalog_alternates_images_and_text_and_is_valid() {
        let entry = entry();
        assert!(catalog::validate_entry(&entry).is_ok());
        let kinds: Vec<ContentKind> = chapters().iter().map(|chapter| chapter.kind).collect();
        assert_eq!(
            kinds,
            [
                ContentKind::Images,
                ContentKind::Text,
                ContentKind::Images,
                ContentKind::Text
            ]
        );
    }

    #[test]
    fn image_pages_are_served_by_the_plugin_and_the_last_text_chapter_fails() {
        let manga = entry();
        let pages = |key: &str| {
            let chapter = chapters().into_iter().find(|c| c.key == key).expect("chapter");
            ReaderHandoffFixture::get_chapter_pages(manga.clone(), chapter)
        };
        assert_eq!(pages("ch1").expect("ch1").len(), 2);
        assert_eq!(pages("ch2").expect("ch2").len(), 2);
        assert!(pages("ch4").is_err());
        assert!(
            ReaderHandoffFixture::handle_image("ch1-1.png")
                .expect("png")
                .starts_with(&[0x89, b'P', b'N', b'G'])
        );
    }
}
