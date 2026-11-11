//! # mnd-core
//!
//! Движок текстовых квестов Meander: модели данных, скриптовый
//! исполнитель, runtime-состояние и сервис сохранений.
//!
//! Крейта **не выполняет никакого I/O**: всё хранилище подключается
//! через порты (traits), поэтому она работает в приложении (через FFI),
//! на сервере и в тестах.

pub mod blocks;
pub mod canvas;
pub mod contracts;
pub mod engine;
pub mod executor;
pub mod expression;
pub mod http;
pub mod image_convert;
pub mod lua;
pub mod models;
pub mod network_safety;
pub mod quest_archive;
pub mod quest_build;
pub mod quest_plan;
pub mod quest_spec;
pub mod quest_store;
pub mod runtime;
pub mod script_format;
pub mod services;
pub mod time;
pub mod validation;

pub use executor::{ExecutionController, ScriptExecutor, event_type};
pub use expression::{EvalValue, ExpressionEvaluator};
pub use models::*;
pub use runtime::{InMemoryScriptRuntimeState, RuntimeError, ScriptRuntime};
