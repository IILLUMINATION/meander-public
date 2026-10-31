use mnd_core::quest_archive;

pub fn quest_archive_import(mnd_path: String, dest_dir: String) -> Result<String, String> {
    quest_archive::quest_archive_import(&mnd_path, &dest_dir).map_err(|e| e.to_string())
}

pub fn quest_archive_export(
    quest_dir: String,
    mnd_path: String,
    password: Option<String>,
) -> Result<(), String> {
    quest_archive::quest_archive_export(&quest_dir, &mnd_path, password).map_err(|e| e.to_string())
}

pub fn quest_archive_export_full(
    quest_dir: String,
    mnd_path: String,
    password: Option<String>,
    include_saves: bool,
    is_protected: bool,
    per_node_nodes: bool,
) -> Result<(), String> {
    quest_archive::quest_archive_export_full(
        &quest_dir,
        &mnd_path,
        password,
        include_saves,
        is_protected,
        per_node_nodes,
    )
    .map_err(|e| e.to_string())
}
