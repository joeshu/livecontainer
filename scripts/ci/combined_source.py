"""Keep self-reinstall feeds within the configured fork and combined artifact."""
from urllib.parse import unquote, urlparse


def is_combined_url(url, repository):
    parsed = urlparse(url)
    prefix = f"/{repository}/releases/download/"
    return (parsed.scheme == "https" and parsed.netloc == "github.com"
            and parsed.path.startswith(prefix)
            and unquote(parsed.path.rsplit("/", 1)[-1]) == "LiveContainer+SideStore.ipa")


def normalize_combined_source(data, repository):
    app = data["apps"][0]
    if app["bundleIdentifier"] != "com.kdt.livecontainer":
        raise ValueError("Combined source has the wrong bundle identifier")
    data.update(website=f"https://github.com/{repository}",
                subtitle=f"LiveContainer+SideStore builds from {repository}.",
                description="LiveContainer with embedded SideStore. Keep app extensions when installing.")
    app["versions"] = [v for v in app.get("versions", []) if is_combined_url(v["downloadURL"], repository)]
    for channel in app.get("releaseChannels", []):
        channel["releases"] = [v for v in channel["releases"] if is_combined_url(v["downloadURL"], repository)]
    data["news"] = [n for n in data.get("news", []) if n.get("url", "").startswith(f"https://github.com/{repository}/")]
    if not app["versions"]:
        raise ValueError("Combined source has no stable release from this repository")
    latest = app["versions"][0]
    app.update(version=latest["version"], versionDate=latest["date"],
               versionDescription=latest.get("localizedDescription", ""),
               downloadURL=latest["downloadURL"], size=latest["size"])
    return data
