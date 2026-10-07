// Tauri command over `osd_core::usage`: what the workbench itself has spent,
// plus what the Claude Code and Codex CLIs spent elsewhere on this machine.
use tauri::AppHandle;

use osd_core::usage::{collect_session_spend, collect_workbench_usage, UsageSummary};

use crate::env_of;

/// `async`: a first scan walks hundreds of transcripts off `~` and opens the
/// runtime's database, which must never run on the UI thread.
///
/// Both bounds are epoch milliseconds supplied by the caller. "Today" begins at
/// the user's own local midnight, which the renderer knows and Rust does not —
/// deriving it here would silently use UTC and hand a user in Asia the wrong
/// day for most of their working hours.
#[tauri::command(async)]
pub fn agent_usage(
    app: AppHandle,
    today_start_ms: i64,
    week_start_ms: i64,
) -> Result<UsageSummary, String> {
    // The fork reports only its own runtime. External CLI history and login
    // credentials require a separately designed, explicit import/consent flow.
    let root = osd_core::runtime::runtime_root(&env_of(&app))?;
    Ok(UsageSummary {
        agents: collect_workbench_usage(&root, today_start_ms, week_start_ms).into_iter().collect(),
        sessions: collect_session_spend(&root, week_start_ms),
        ..UsageSummary::default()
    })
}

/// Which of the given commands this machine can run.
///
/// The renderer owns the catalog of agents it knows how to drive; only this
/// side can answer whether the binary exists.
#[tauri::command(async)]
pub fn detect_commands(commands: Vec<String>) -> Vec<String> {
    osd_core::which::detect_installed(&commands)
}
