# dmgbuild settings for the Mac host's disk image (Scripts/release-mac-host.sh): a fixed window with no toolbar,
# the app and an Applications link side by side over a background with an arrow. Geometry matches
# Scripts/release/dmg-background.swift. dmgbuild writes the Finder layout (.DS_Store) itself, without scripting
# Finder, so it builds the same unattended.
# Defines passed with -D: app (path to LainHost.app), background (path to the .tiff), icon (optional .icns).
import os.path

application = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
if defines.get("icon"):  # noqa: F821
    icon = defines["icon"]  # noqa: F821

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {appname: (170, 190), "Applications": (470, 190)}
hide_extensions = [appname]
