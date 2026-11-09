//! Потоковая выдача против настоящих архивов: квест собирается тем же
//! экспортёром, что у редактора, артефакты строит сервер, а boot-бандл затем
//! открывает нативный импортёр `mnd-core`.
//!
//! Это сквозная проверка контракта «экспорт → публикация → раздача»: если
//! boot перестанет быть полноценным квестом для движка или потеряет текстовую
//! часть, ломается именно здесь.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use mnd_core::quest_archive::{quest_archive_export_full, quest_archive_import};
use mnd_server::services::quest_stream::{boot_path, build_artifacts, mnd_path};
use serde_json::Value;
use uuid::Uuid;

/// Мини-квест в раскладке каталога: текст, один шрифт, одно медиа, локальный сейв.
///
/// `per_node` выбирает раскладку нод на диске — её же выбирает экспортёр, а
/// именно v2 (`nodes/index.json` + тела) либо монолит `nodes.json`.
fn write_quest(dir: &Path, per_node: bool) {
    let mut files: Vec<(String, String)> = vec![
        (
            "config.json".into(),
            r#"{"id":"roundtrip","title":"Круговорот","startNodeId":"n1"}"#.into(),
        ),
        ("res/templates.json".into(), r#"[{"id":"t1"}]"#.into()),
        (
            "res/metadata.json".into(),
            r#"{"x.png":{"name":"закат"}}"#.into(),
        ),
        ("res/images/x.png".into(), "PNGDATA".into()),
        ("res/fonts/Fira.ttf".into(), "TTFDATA".into()),
        ("scripts/s1.json".into(), r#"{"blocks":[]}"#.into()),
        ("saves/1.json".into(), r#"{"node":"n2"}"#.into()),
    ];
    if per_node {
        files.push((
            "nodes/index.json".into(),
            r#"{"format_version":2,"nodes":[{"id":"n1","title":"Старт"},{"id":"n2","title":"Дальше"}],"groups":[],"comments":[],"edges":[]}"#
                .into(),
        ));
        files.push(("nodes/n1.json".into(), r#"{"id":"n1","content":[]}"#.into()));
        files.push(("nodes/n2.json".into(), r#"{"id":"n2","content":[]}"#.into()));
    } else {
        files.push((
            "nodes.json".into(),
            r#"{"nodes":[{"id":"n1","title":"Старт","content":[]},{"id":"n2","title":"Дальше","content":[]}]}"#
                .into(),
        ));
    }
    for (rel, text) in files.drain(..) {
        let path = dir.join(&rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
}

fn export(quest_dir: &Path, out: &Path, per_node: bool) {
    quest_archive_export_full(
        quest_dir.to_str().unwrap(),
        out.to_str().unwrap(),
        None,
        false,
        false,
        per_node,
    )
    .unwrap();
}

/// Ноды, как их видит нативная сторона после импорта: монолит или per-node
/// раскладка — в обоих случаях набор id один и тот же.
fn node_ids(quest_dir: &Path) -> BTreeSet<String> {
    let document: Value = ["nodes.json", "nodes/index.json"]
        .iter()
        .map(|rel| quest_dir.join(rel))
        .find(|path| path.is_file())
        .map(|path| serde_json::from_slice(&fs::read(path).unwrap()).unwrap())
        .expect("в импортированном квесте нет нод");
    document["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|node| node["id"].as_str().unwrap().to_string())
        .collect()
}

fn import(mnd: &Path, into: &Path) -> PathBuf {
    quest_archive_import(mnd.to_str().unwrap(), into.to_str().unwrap()).unwrap();
    into.to_path_buf()
}

fn run_roundtrip(per_node: bool) {
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("source");
    write_quest(&source, per_node);

    // Публикация: редактор отдаёт `.mnd`, сервер кладёт его в каталог раздачи.
    let exported = tmp.path().join("exported.mnd");
    export(&source, &exported, per_node);
    let quests = tmp.path().join("quests_files");
    fs::create_dir_all(&quests).unwrap();
    let id = Uuid::new_v4();
    fs::copy(&exported, mnd_path(&quests, id)).unwrap();

    let manifest = build_artifacts(&quests, id).unwrap();
    assert_eq!(
        manifest["format"],
        if per_node { "per-node" } else { "legacy" }
    );

    // Нативный импорт исходника — эталон.
    let original = import(&mnd_path(&quests, id), &tmp.path().join("original"));

    // Boot-бандл обязан быть полноценным квестом: импорт проходит, ноды и
    // конфиг совпадают с исходником.
    let boot = import(&boot_path(&quests, id), &tmp.path().join("boot"));
    assert_eq!(node_ids(&boot), node_ids(&original));
    assert_eq!(
        fs::read(original.join("config.json")).unwrap(),
        fs::read(boot.join("config.json")).unwrap()
    );

    // Ленивые записи: медиа в boot не уехало, но выдаётся по требованию.
    let manifest_paths: Vec<&str> = manifest["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["path"].as_str().unwrap())
        .collect();
    assert!(manifest_paths.contains(&"res/images/x.png"));
    assert!(!manifest_paths.contains(&"saves/1.json"));
    assert!(!boot.join("res/images/x.png").exists());

    let image =
        mnd_server::services::quest_stream::ensure_entry(&quests, id, "res/images/x.png").unwrap();
    assert_eq!(fs::read(image).unwrap(), b"PNGDATA");
}

#[test]
fn legacy_quest_roundtrips_through_boot_bundle() {
    run_roundtrip(false);
}

#[test]
fn per_node_quest_roundtrips_through_boot_bundle() {
    run_roundtrip(true);
}
