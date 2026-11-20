"""One display-name function for every addon. Repo slugs, code identifiers, install paths and addons.lock names stay
"dot-*"; only visible text (banner title and alt text, README headings, asset titles) uses the display name.

  dot-npc-ai-director -> "NPC AI Director"     dot-peer-to-peer -> "Peer-to-Peer"     dot-2d -> "2D"

  python3 display_name.py dot-cloud [...]      print display names
"""
import sys

ACRONYMS = {"2d": "2D", "3d": "3D", "npc": "NPC", "ai": "AI", "sql": "SQL", "fx": "FX", "ui": "UI", "hud": "HUD",
            "rcon": "RCON", "tdm": "TDM", "p2p": "P2P", "bsp": "BSP", "api": "API", "http": "HTTP", "vfx": "VFX"}
SPECIAL = {"peer-to-peer": "Peer-to-Peer"}


def display_name(slug):
    s = slug[4:] if slug.startswith("dot-") else slug
    if s in SPECIAL:
        return SPECIAL[s]
    return " ".join(ACRONYMS.get(w, w.capitalize()) for w in s.split("-") if w)


if __name__ == "__main__":
    for a in sys.argv[1:]:
        print(display_name(a))
