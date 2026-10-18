use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct App {
    pub id: u64,
    pub name: String,
    pub address: String,
    #[serde(default)]
    pub description: String,
    #[serde(default = "default_category")]
    pub category: String,
    #[serde(default = "default_logo")]
    pub logo: String,
    #[serde(default)]
    pub favorite: bool,
}

fn default_category() -> String {
    "Utilities".into()
}
fn default_logo() -> String {
    "auto".into()
}

pub fn validate(mut app: App) -> Result<App, String> {
    app.name = app.name.trim().into();
    app.description = app.description.trim().into();
    app.category = app.category.trim().into();
    if app.name.is_empty() || app.name.chars().count() > 80 {
        return Err("Use an app name of 1–80 characters.".into());
    }
    if app.description.chars().count() > 160 {
        return Err("Keep the description under 160 characters.".into());
    }
    if app.category.is_empty() || app.category.chars().count() > 40 {
        return Err("Use a category of 1–40 characters.".into());
    }
    let address = app.address.trim();
    if address.len() > 2048 {
        return Err("The address is too long.".into());
    }
    let address = if address.contains("://") {
        address.to_owned()
    } else {
        format!("http://{address}")
    };
    let parsed =
        url::Url::parse(&address).map_err(|_| "Enter a valid IP address or HTTP(S) URL.")?;
    if !matches!(parsed.scheme(), "http" | "https")
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err("Use an HTTP(S) address without embedded credentials.".into());
    }
    app.address = parsed.to_string();
    let builtin = [
        "auto",
        "server",
        "jellyfin",
        "proxmox",
        "home-assistant",
        "pi-hole",
        "immich",
        "truenas",
        "portainer",
        "grafana",
    ];
    let image = [
        "data:image/png;base64,",
        "data:image/jpeg;base64,",
        "data:image/webp;base64,",
    ]
    .iter()
    .any(|prefix| {
        app.logo.strip_prefix(prefix).is_some_and(|body| {
            !body.is_empty()
                && body
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
        })
    });
    let remote = url::Url::parse(&app.logo).ok().is_some_and(|url| {
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
    });
    if app.logo.len() > 48_000 || !(builtin.contains(&app.logo.as_str()) || image || remote) {
        return Err("Choose a bundled logo, a small image, or an HTTP(S) image URL.".into());
    }
    Ok(app)
}
pub async fn persist(path: &std::path::Path, apps: &[App]) -> std::io::Result<()> {
    use tokio::io::AsyncWriteExt;
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        tokio::fs::create_dir_all(parent).await?;
    }
    let bytes = serde_json::to_vec(apps)?;
    let temp = path.with_extension("json.tmp");
    let mut file = tokio::fs::File::create(&temp).await?;
    file.write_all(&bytes).await?;
    file.sync_all().await?;
    drop(file);
    tokio::fs::rename(&temp, path).await?;
    Ok(())
}

pub fn reorder(apps: &[App], ids: &[u64]) -> Result<Vec<App>, String> {
    use std::collections::HashMap;
    let mut by_id: HashMap<_, _> = apps.iter().map(|app| (app.id, app)).collect();
    if ids.len() != apps.len() || by_id.len() != apps.len() {
        return Err("The app list changed. Reload before reordering.".into());
    }
    ids.iter()
        .map(|id| {
            by_id
                .remove(id)
                .cloned()
                .ok_or_else(|| "The app list changed. Reload before reordering.".into())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn app() -> App {
        App {
            id: 1,
            name: " Server ".into(),
            address: "192.168.1.2:8006".into(),
            description: "".into(),
            category: "Infrastructure".into(),
            logo: "server".into(),
            favorite: false,
        }
    }
    #[test]
    fn accepts_minimal_apps_with_automatic_logos() {
        let input: Result<App, _> =
            serde_json::from_str(r#"{"id":0,"name":"NAS","address":"nas.local","logo":"auto"}"#);
        assert!(input.is_ok());
        assert!(validate(input.unwrap()).is_ok());
    }
    #[test]
    fn reorders_without_changing_app_data() {
        let one = app();
        let mut two = app();
        two.id = 2;
        two.name = "Other".into();
        assert_eq!(
            reorder(&[one.clone(), two.clone()], &[2, 1]).unwrap(),
            vec![two, one]
        );
        assert_eq!(reorder(&[], &[]).unwrap(), vec![]);
    }
    #[test]
    fn rejects_missing_duplicate_and_unknown_order_ids() {
        let mut two = app();
        two.id = 2;
        let apps = vec![app(), two];
        for ids in [vec![1], vec![1, 1], vec![1, 9], vec![1, 2, 3]] {
            assert!(reorder(&apps, &ids).is_err());
        }
    }
    #[test]
    fn normalizes_lan_addresses() {
        let result = validate(app()).unwrap();
        assert_eq!(result.address, "http://192.168.1.2:8006/");
        assert_eq!(result.name, "Server");
    }
    #[test]
    fn rejects_unsafe_or_invalid_inputs() {
        for address in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "https://",
            "http://user:pass@server",
            "http://bad host",
        ] {
            let mut input = app();
            input.address = address.into();
            assert!(validate(input).is_err(), "{address}");
        }
        let mut input = app();
        input.name = " ".into();
        assert!(validate(input).is_err());
        let mut input = app();
        input.logo = "javascript:alert(1)".into();
        assert!(validate(input).is_err());
        let mut input = app();
        input.name = "a".repeat(81);
        assert!(validate(input).is_err());
    }
    #[test]
    fn supports_ipv6_and_https() {
        for address in ["http://[::1]:8096", "https://nas.local/path?q=1"] {
            let mut input = app();
            input.address = address.into();
            assert!(validate(input).is_ok());
        }
    }
    #[tokio::test]
    async fn saves_and_reloads_without_truncation() {
        let dir = std::env::temp_dir().join(format!("perch-test-{}", std::process::id()));
        let path = dir.join("apps.json");
        persist(&path, &[app()]).await.unwrap();
        let loaded: Vec<App> =
            serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
        assert_eq!(loaded, vec![app()]);
        persist(&path, &[]).await.unwrap();
        assert_eq!(tokio::fs::read_to_string(&path).await.unwrap(), "[]");
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[tokio::test]
    async fn reports_failed_writes() {
        let path = std::env::temp_dir().join(format!("perch-block-{}", std::process::id()));
        tokio::fs::write(&path, b"block").await.unwrap();
        assert!(persist(&path.join("apps.json"), &[app()]).await.is_err());
        assert_eq!(tokio::fs::read(&path).await.unwrap(), b"block");
        tokio::fs::remove_file(path).await.unwrap();
    }
}
