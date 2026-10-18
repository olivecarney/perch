use perch::model::{App, persist, reorder, validate};
use std::{path::PathBuf, sync::OnceLock};
use tokio::sync::Mutex;
use topcoat::{
    Result,
    context::Cx,
    router::{
        Body, Router,
        content::{Css, Js, Json},
        error::{bad_request, not_found},
        page, path_param,
        response::Response,
        route,
    },
    view::{Unescaped, View, view},
};

struct Store {
    apps: Vec<App>,
    path: PathBuf,
}
static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
fn store() -> &'static Mutex<Store> {
    STORE.get().expect("store initialized before serving")
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let path =
        PathBuf::from(std::env::var("PERCH_DATA").unwrap_or_else(|_| "data/apps.json".into()));
    let apps: Vec<App> = match tokio::fs::read(&path).await {
        Ok(bytes) => serde_json::from_slice(&bytes)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => return Err(e.into()),
    };
    if apps.len() > 256 {
        return Err(bad_request("The app file exceeds 256 apps.").into());
    }
    let apps = apps
        .into_iter()
        .map(validate)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(bad_request)?;
    STORE
        .set(Mutex::new(Store { apps, path }))
        .ok()
        .expect("initialize once");
    println!(
        "Perch · http://{}:{}",
        std::env::var("HOST").unwrap_or_else(|_| "127.0.0.1".into()),
        std::env::var("PORT").unwrap_or_else(|_| "3000".into())
    );
    topcoat::start(
        Router::builder()
            .page(home)
            .route(styles)
            .route(font)
            .route(script)
            .route(logo_script)
            .route(icons)
            .route(get_apps)
            .route(mutate)
            .build(),
    )
    .await?;
    Ok(())
}

#[page("/")]
async fn home() -> Result<impl View> {
    Ok(view! {
        <!DOCTYPE html>
        <html lang="en">
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta name="theme-color" content="#111111">
                <title>"Perch"</title>
                <link rel="icon" href="/icons/server.svg" type="image/svg+xml">
                <link rel="preload" href="/fonts/jetbrains-mono-v1.woff2" as="font" type="font/woff2" crossorigin="anonymous">
                <link rel="stylesheet" href="/app.css">
                <script src="/app.js" type="module"></script>
            </head>
            <body>(Unescaped::new_unchecked(include_str!("../public/shell.html")))</body>
        </html>
    })
}
#[route(GET "/app.css")]
async fn styles() -> Result<Css<&'static str>> {
    Ok(Css(include_str!("../public/app.css")))
}
#[route(GET "/app.js")]
async fn script() -> Result<Js<&'static str>> {
    Ok(Js(include_str!("../public/app.js")))
}
#[route(GET "/logos.mjs")]
async fn logo_script() -> Result<Js<&'static str>> {
    Ok(Js(include_str!("../public/logos.mjs")))
}
#[route(GET "/fonts/jetbrains-mono-v1.woff2")]
async fn font() -> Result<Response> {
    Ok(Response::builder()
        .header("Content-Type", "font/woff2")
        .header("Cache-Control", "public, max-age=31536000, immutable")
        .body(Body::from(
            &include_bytes!("../public/fonts/JetBrainsMono-Regular.woff2")[..],
        ))?)
}
path_param!(logo);
#[route(GET "/icons/{logo}")]
async fn icons(cx: &Cx) -> Result<Response> {
    let svg = match path_param::<Logo>(cx) {
        "server.svg" => include_str!("../public/icons/server.svg"),
        "jellyfin.svg" => include_str!("../public/icons/jellyfin.svg"),
        "proxmox.svg" => include_str!("../public/icons/proxmox.svg"),
        "home-assistant.svg" => include_str!("../public/icons/home-assistant.svg"),
        "pi-hole.svg" => include_str!("../public/icons/pi-hole.svg"),
        "immich.svg" => include_str!("../public/icons/immich.svg"),
        "truenas.svg" => include_str!("../public/icons/truenas.svg"),
        "portainer.svg" => include_str!("../public/icons/portainer.svg"),
        "grafana.svg" => include_str!("../public/icons/grafana.svg"),
        _ => return Err(not_found().into()),
    };
    Ok(Response::builder()
        .header("Content-Type", "image/svg+xml")
        .header("Cache-Control", "public, max-age=86400")
        .body(Body::from(svg))?)
}
#[route(GET "/api/apps")]
async fn get_apps() -> Result<Json<Vec<App>>> {
    Ok(Json(store().lock().await.apps.clone()))
}

#[derive(serde::Deserialize)]
#[serde(tag = "action", rename_all = "lowercase")]
enum Mutation {
    Save { app: App },
    Delete { id: u64 },
    Reorder { ids: Vec<u64> },
}
#[route(POST "/api/apps")]
async fn mutate(body: Body) -> Result<Json<Vec<App>>> {
    let bytes = topcoat::router::to_bytes(body, 64_000).await?;
    let mutation: Mutation =
        serde_json::from_slice(&bytes).map_err(|_| bad_request("Invalid app data."))?;
    let mut state = store().lock().await;
    let mut next = state.apps.clone();
    match mutation {
        Mutation::Save { app } => {
            let mut app = validate(app).map_err(bad_request)?;
            if app.id == 0 {
                if next.len() >= 256 {
                    return Err(bad_request("Perch supports up to 256 apps.").into());
                }
                app.id = next
                    .iter()
                    .map(|a| a.id)
                    .max()
                    .unwrap_or(0)
                    .checked_add(1)
                    .ok_or_else(|| bad_request("App ID limit reached."))?;
                next.push(app);
            } else {
                let entry = next
                    .iter_mut()
                    .find(|a| a.id == app.id)
                    .ok_or_else(not_found)?;
                *entry = app;
            }
        }
        Mutation::Reorder { ids } => {
            next = reorder(&next, &ids).map_err(bad_request)?;
        }
        Mutation::Delete { id } => {
            let index = next.iter().position(|a| a.id == id).ok_or_else(not_found)?;
            next.remove(index);
        }
    }
    persist(&state.path, &next).await?;
    state.apps = next;
    Ok(Json(state.apps.clone()))
}
