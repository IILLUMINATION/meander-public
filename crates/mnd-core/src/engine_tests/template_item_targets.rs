// `set_image`/`set_visible` из мастера шаблона должны попадать в копии.
//
// Скрипт — ассет мастера: он адресует айтем по id мастера (`master-ico`).
// В инстансе тот же айтем раскрывается под производным `tpl_<sha1>` id, и
// раньше переопределение ложилось только на id мастера: в мастере картинка
// менялась, в копиях (HUD в каждой ноде) — нет. Движок теперь переводит id
// мастера в id всех инстансов, поэтому смена видна везде.

use super::*;

fn template(kind: &str, payload: Value) -> TemplateItem {
    TemplateItem::from_json(&serde_json::json!({
        "id": "tpl-hud",
        "name": "HUD",
        "kind": kind,
        "payload": payload,
    }))
}

fn engine_with_hud(
    nodes: Vec<SavedNode>,
    templates: Vec<TemplateItem>,
    embedded_scripts: HashMap<String, Value>,
) -> GameEngine {
    GameEngine::new(
        "q_tpl".to_string(),
        Quest::from_json(&serde_json::json!({
            "id": "q_tpl",
            "title": "Templates",
            "version": "2.0.0",
            "startNodeId": "node_1",
        })),
        nodes,
        templates,
        GameEngineConfig {
            platform: PlatformInfo::default(),
            embedded_scripts,
            asset_store: None,
            save_store: None,
        },
    )
}

fn source_of(engine: &GameEngine, item_id: &str) -> Option<String> {
    engine
        .state
        .get_variable("_internal_item_sources")
        .and_then(|v| v.get(item_id))
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn hud_template() -> TemplateItem {
    template(
        "column",
        serde_json::json!({
            "type": "column",
            "id": "master-hud",
            "children": [
                {"type": "image", "id": "master-ico", "resourcePath": "res/a.png"}
            ]
        }),
    )
}

#[test]
fn set_image_from_template_master_reaches_every_instance() {
    let mut scripts = HashMap::new();
    scripts.insert(
        "scripts/swap.json".to_string(),
        serde_json::json!({
            "name": "swap",
            "blocks": [{"type": "set_image", "item_id": "master-ico", "source": "res/b.png"}],
        }),
    );

    let nodes = vec![
        SavedNode::from_json(&serde_json::json!({
            "id": "node_1",
            "title": "Start",
            "content": { "items": [
                {"type": "column", "id": "hud-1", "templateRef": "tpl-hud"}
            ]},
            "scriptAssetId": "scripts/swap.json",
        })),
        SavedNode::from_json(&serde_json::json!({
            "id": "node_2",
            "title": "Second",
            "content": { "items": [
                {"type": "column", "id": "hud-2", "templateRef": "tpl-hud"}
            ]},
        })),
    ];

    let mut engine = engine_with_hud(nodes, vec![hud_template()], scripts);
    engine.start_new(None).unwrap();

    // id мастера — чтобы сам мастер-шаблон показывал новую картинку.
    assert_eq!(
        source_of(&engine, "master-ico").as_deref(),
        Some("res/b.png")
    );

    // Копии: id айтема в инстансах считается так же, как при раскрытии.
    let in_first = derive_template_id("hud-1", "$.children[0]");
    let in_second = derive_template_id("hud-2", "$.children[0]");
    assert_eq!(source_of(&engine, &in_first).as_deref(), Some("res/b.png"));
    assert_eq!(source_of(&engine, &in_second).as_deref(), Some("res/b.png"));
}

#[test]
fn set_visible_from_template_master_reaches_every_instance() {
    let mut scripts = HashMap::new();
    scripts.insert(
        "scripts/hide.json".to_string(),
        serde_json::json!({
            "name": "hide",
            "blocks": [{"type": "set_visible", "item_id": "master-ico", "mode": "hide"}],
        }),
    );

    let nodes = vec![
        SavedNode::from_json(&serde_json::json!({
            "id": "node_1",
            "title": "Start",
            "content": { "items": [
                {"type": "column", "id": "hud-1", "templateRef": "tpl-hud"}
            ]},
            "scriptAssetId": "scripts/hide.json",
        })),
        SavedNode::from_json(&serde_json::json!({
            "id": "node_2",
            "title": "Second",
            "content": { "items": [
                {"type": "column", "id": "hud-2", "templateRef": "tpl-hud"}
            ]},
        })),
    ];

    let mut engine = engine_with_hud(nodes, vec![hud_template()], scripts);
    engine.start_new(None).unwrap();

    let hidden = engine
        .state
        .get_variable("_internal_item_hidden")
        .cloned()
        .expect("set_visible должен был записать переопределение");
    for id in [
        "master-ico".to_string(),
        derive_template_id("hud-1", "$.children[0]"),
        derive_template_id("hud-2", "$.children[0]"),
    ] {
        assert_eq!(
            hidden.get(&id).and_then(Value::as_str),
            Some("hidden"),
            "id {id} остался без переопределения"
        );
    }
}

#[test]
fn node_template_instances_get_derived_targets() {
    // Шаблон-нода: его скрипт адресует айтем по id мастера, а в инстансах
    // путь начинается с `$.items[i]` — проверяем именно эту ветку.
    let node_template = template(
        "node",
        serde_json::json!({
            "id": "master-node",
            "title": "HUD",
            "content": { "items": [
                {"type": "image", "id": "master-ico", "resourcePath": "res/a.png"}
            ]},
            "scriptAssetId": "scripts/swap.json",
        }),
    );
    let mut scripts = HashMap::new();
    scripts.insert(
        "scripts/swap.json".to_string(),
        serde_json::json!({
            "name": "swap",
            "blocks": [{"type": "set_image", "item_id": "master-ico", "source": "res/c.png"}],
        }),
    );

    let nodes = vec![
        SavedNode::from_json(&serde_json::json!({
            "id": "node_1",
            "title": "Start",
            "templateRef": "tpl-hud",
        })),
        SavedNode::from_json(&serde_json::json!({
            "id": "node_2",
            "title": "Second",
            "templateRef": "tpl-hud",
        })),
    ];

    let mut engine = engine_with_hud(nodes, vec![node_template], scripts);
    engine.start_new(None).unwrap();

    assert_eq!(
        source_of(&engine, "master-ico").as_deref(),
        Some("res/c.png")
    );
    for instance in ["node_1", "node_2"] {
        let id = derive_template_id(instance, "$.items[0]");
        assert_eq!(
            source_of(&engine, &id).as_deref(),
            Some("res/c.png"),
            "инстанс {instance} не обновился"
        );
    }
}
