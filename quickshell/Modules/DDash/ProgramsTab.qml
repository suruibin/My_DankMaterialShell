pragma ComponentBehavior: Bound

import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Common
import qs.Modals.FileBrowser
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.DDash

Item {
    id: root

    property string entryId: "programs"
    property bool live: Window.window?.visible ?? false
    property bool editMode: false
    property Item parentPopout: null
    readonly property Item focusTarget: focusGrabber
    readonly property var menuActions: [
        {
            label: I18n.tr("Settings"),
            iconName: "settings",
            action: () => {
                if (parentPopout) parentPopout.dashVisible = false
                PopoutService.closeDankDash?.()
                PopoutService.openSettingsWithTab?.("dank_dash")
            }
        }
    ]

    function handleKeyEvent(event) { return false }

    // ── AppDrawer state ──────────────────────────────────────
    property var appList: []
    property int appCount: 0
    property var appImageApps: []
    property var desktopAppsList: []
    property var pendingIconUpdates: []
    property bool extractingIcons: false
    property int extractTotal: 0
    property int extractDone: 0
    property int extractGeneration: 0
    property var cachedIcons: ({})
    property bool initialized: false
    property bool iconSizeLoaded: false
    property int iconSize: 36

    onAppListChanged: {
        appImageApps = appList.filter((a) => !a.isDesktop);
        desktopAppsList = appList.filter((a) => a.isDesktop);
    }

    property string homeDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.HomeLocation))
    property string configDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.ConfigLocation)) + "/DankMaterialShell"
    property string iconCacheDir: configDir + "/appicons"
    property string savedAppsFile: configDir + "/desktop_apps.json"
    property string desktopCacheFile: configDir + "/desktop_cache.json"
    property string iconSizeFile: configDir + "/appdrawer_iconsize.json"
    property string appImageDir: homeDir
    property string appImageDirFile: configDir + "/appdrawer_dir.json"

    readonly property int _cellHeight: Math.round(iconSize * 2.0 + 30)
    readonly property int _columns: Math.max(4, Math.min(8, Math.round(700 / (iconSize + 16))))
    readonly property int _sourceSize: iconSize * 2

    implicitHeight: contentColumn.implicitHeight
    implicitWidth: contentColumn.implicitWidth

    function findIconFile(appName) {
        var lowerName = appName.toLowerCase();
        if (cachedIcons[lowerName]) return cachedIcons[lowerName];
        var files = Process.execute("sh", ["-c", "ls -1 '" + iconCacheDir + "/" + appName + "'.* 2>/dev/null | head -1"]);
        if (files && files.trim().length > 0 && files.exitCode === 0) {
            return files.stdout.trim();
        }
        return null;
    }

    function getIconPath(appName) {
        var iconFile = findIconFile(appName);
        if (iconFile) return iconFile;
        return "";
    }

    function getAppNameFromFilename(filename) {
        var base = filename.replace(/\.AppImage$/i, "").replace(/[\s-_]+/g, "");
        return base || filename;
    }

    function getDisplayName(appName) {
        return appName.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_-]/g, " ").trim();
    }

    function extractAppImageIcon(appPath, appName, callback) {
        var tmpDir = iconCacheDir + "/tmp-" + appName;
        var cpPng = "cp \"$REAL_FILE\" '" + iconCacheDir + "/" + appName + ".png' 2>/dev/null && FOUND_ICON=1 && break; fi; ";
        var cpSvg = "cp \"$REAL_FILE\" '" + iconCacheDir + "/" + appName + ".svg' 2>/dev/null && FOUND_ICON=1 && break; fi; ";
        var cpAny = "EXT=\"${REAL_FILE##*.}\"; case \"$EXT\" in png|svg|jpg|jpeg|ico|xpm) ;; *) EXT=png ;; esac; cp \"$REAL_FILE\" \"" + iconCacheDir + "/" + appName + ".$EXT\" 2>/dev/null && FOUND_ICON=1 && break; fi; ";
        var cpAnyOnce = "EXT=\"${REAL_FILE##*.}\"; case \"$EXT\" in png|svg|jpg|jpeg|ico|xpm) ;; *) EXT=png ;; esac; cp \"$REAL_FILE\" \"" + iconCacheDir + "/" + appName + ".$EXT\" 2>/dev/null && FOUND_ICON=1; fi; ";
        var resolve = "REAL_FILE=$(readlink -f \"$icon\" 2>/dev/null || echo \"$icon\"); if [ -f \"$REAL_FILE\" ]; then ";
        var findPng = "find squashfs-root -xtype f -name '*.png' -printf '%s\\t%p\\n' 2>/dev/null | sort -rn | head -3 | cut -f2-";
        var findSvg = "find squashfs-root -xtype f -name '*.svg' -printf '%s\\t%p\\n' 2>/dev/null | sort -rn | head -3 | cut -f2-";
        var findAny = "find squashfs-root -maxdepth 7 -xtype f \\( -name '.DirIcon' -o -name '*.png' -o -name '*.svg' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.ico' -o -name '*.xpm' \\) -printf '%s\\t%p\\n' 2>/dev/null | sort -rn | head -3 | cut -f2-";
        Proc.runCommand(
            "extract-icon-" + appName,
            ["sh", "-c",
                "mkdir -p '" + iconCacheDir + "' && rm -rf '" + tmpDir + "' && mkdir -p '" + tmpDir + "' && cd '" + tmpDir + "' && " +
                "FOUND_ICON=0; IFS='\n'; " +
                "timeout 45 '" + appPath + "' --appimage-extract '*.png' >/dev/null 2>&1; " +
                "for icon in $(" + findPng + "); do " + resolve + cpPng + "done; " +
                "if [ \"$FOUND_ICON\" = 0 ]; then rm -rf squashfs-root; " +
                "timeout 45 '" + appPath + "' --appimage-extract '*.svg' >/dev/null 2>&1; " +
                "for icon in $(" + findSvg + "); do " + resolve + cpSvg + "done; fi; " +
                "if [ \"$FOUND_ICON\" = 0 ]; then rm -rf squashfs-root; " +
                "timeout 45 '" + appPath + "' --appimage-extract '.DirIcon' >/dev/null 2>&1; " +
                "if [ -e squashfs-root/.DirIcon ]; then " +
                "REAL_FILE=$(readlink -f squashfs-root/.DirIcon 2>/dev/null || echo squashfs-root/.DirIcon); " +
                "if case \"$REAL_FILE\" in squashfs-root/*) [ -f \"$REAL_FILE\" ] ;; *) false ;; esac; then " +
                cpAnyOnce + "fi; fi; " +
                "if [ \"$FOUND_ICON\" = 0 ]; then " +
                "timeout 45 '" + appPath + "' --appimage-extract 'usr/share/icons/*' >/dev/null 2>&1; " +
                "timeout 45 '" + appPath + "' --appimage-extract 'usr/share/pixmaps/*' >/dev/null 2>&1; " +
                "for icon in $(find squashfs-root -xtype f \\( -name '*.png' -o -name '*.svg' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.ico' -o -name '*.xpm' \\) -printf '%s\\t%p\\n' 2>/dev/null | sort -rn | head -3 | cut -f2-); do " +
                resolve + cpAny + "done; fi; " +
                "if [ \"$FOUND_ICON\" = 0 ]; then rm -rf squashfs-root; " +
                "timeout 45 '" + appPath + "' --appimage-extract >/dev/null 2>&1; " +
                "for icon in $(" + findAny + "); do " + resolve + cpAny + "done; fi; " +
                "rm -rf '" + tmpDir + "'; " +
                "ls -1 '" + iconCacheDir + "/" + appName + "'.* 2>/dev/null | head -1 || echo 'failed'"
            ],
            function(output, exitCode) {
                if (output && output.trim().length > 0 && !output.includes("failed")) {
                    var lowerName = appName.toLowerCase();
                    cachedIcons[lowerName] = output.trim();
                }
                if (callback) callback(exitCode);
            },
            0,
            90000
        );
    }

    function scanApps() {
        loadCachedIcons(function() {
            Proc.runCommand(
                "scan-appimages",
                ["sh", "-c", "ls -1 '" + appImageDir + "'/*.AppImage 2>/dev/null || true"],
                function(output, exitCode) {
                    var newList = [];
                    if (exitCode === 0 && output && output.trim().length > 0) {
                        var files = output.trim().split("\n").filter(f => f.length > 0);
                        var needExtract = [];
                        for (let i = 0; i < files.length; i++) {
                            var filePath = files[i];
                            var filename = filePath.split("/").pop();
                            var appName = getAppNameFromFilename(filename);
                            var displayName = getDisplayName(appName);
                            var iconFile = findIconFile(appName);
                            var hasIcon = iconFile !== null;
                            newList.push({
                                name: displayName,
                                appName: appName,
                                path: filePath,
                                iconPath: iconFile || "",
                                iconExtracted: hasIcon,
                                isDesktop: false
                            });
                            if (!hasIcon) {
                                needExtract.push({ index: i, appName: appName, path: filePath });
                            }
                        }
                        if (needExtract.length > 0) {
                            extractGeneration++;
                            extractTotal = needExtract.length;
                            extractDone = 0;
                            extractingIcons = true;
                            extractIconsInBackground(needExtract, extractGeneration);
                        }
                    }
                    loadSavedDesktopApps((saved) => {
                        appList = newList.concat(saved);
                        appCount = appList.length;
                    });
                },
                0,
                10000
            );
        });
    }

    function extractIconsInBackground(apps, gen) {
        if (apps.length === 0) return;
        if (gen !== extractGeneration) return;
        var app = apps[0];
        var remaining = apps.slice(1);
        extractAppImageIcon(app.path, app.appName, function(exitCode) {
            if (gen !== extractGeneration) return;
            pendingIconUpdates.push({ path: app.path, appName: app.appName });
            extractDone++;
            if (remaining.length > 0) {
                extractIconsInBackground(remaining, gen);
            } else {
                applyPendingIconUpdates();
                extractingIcons = false;
            }
        });
    }

    function applyPendingIconUpdates() {
        if (pendingIconUpdates.length === 0) return;
        var updates = pendingIconUpdates;
        pendingIconUpdates = [];
        var newList = appList.slice();
        for (var i = 0; i < updates.length; i++) {
            var u = updates[i];
            var lowerName = u.appName.toLowerCase();
            var iconPath = cachedIcons[lowerName];
            if (!iconPath) continue;
            for (var j = 0; j < newList.length; j++) {
                if (newList[j].path === u.path) {
                    newList[j].iconPath = iconPath;
                    newList[j].iconExtracted = true;
                    break;
                }
            }
        }
        appList = newList;
    }

    function loadCachedIcons(callback) {
        Proc.runCommand(
            "load-cache",
            ["sh", "-c", "ls -1 '" + iconCacheDir + "' 2>/dev/null || true"],
            function(output, exitCode) {
                if (exitCode === 0 && output && output.trim().length > 0) {
                    var files = output.trim().split("\n");
                    for (var i = 0; i < files.length; i++) {
                        var f = files[i];
                        var name = f.replace(/\.[^.]+$/, "").toLowerCase();
                        cachedIcons[name] = iconCacheDir + "/" + f;
                    }
                }
                if (callback) callback();
            },
            0,
            5000
        );
    }

    function loadIconSize() {
        Proc.runCommand(
            "load-iconsize",
            ["sh", "-c", "cat '" + iconSizeFile + "' 2>/dev/null || echo ''"],
            function(output, exitCode) {
                if (exitCode === 0 && output && output.trim().length > 0) {
                    var v = parseInt(output.trim(), 10);
                    if (v >= 24 && v <= 64) iconSize = v;
                }
                iconSizeLoaded = true;
            },
            0,
            5000
        );
    }

    function saveIconSize() {
        Proc.runCommand(
            "save-iconsize",
            ["sh", "-c", "mkdir -p '" + configDir + "' && echo '" + iconSize + "' > '" + iconSizeFile + "'"],
            null,
            0,
            5000
        );
    }

    onIconSizeChanged: {
        if (iconSizeLoaded) saveIconSize();
    }

    function loadAppImageDir() {
        Proc.runCommand(
            "load-appdir",
            ["sh", "-c", "cat '" + appImageDirFile + "' 2>/dev/null || echo ''"],
            function(output, exitCode) {
                if (exitCode === 0 && output && output.trim().length > 0) {
                    var v = output.trim();
                    if (v.length > 0) appImageDir = v;
                }
            },
            0,
            5000
        );
    }

    function saveAppImageDir() {
        Proc.runCommand(
            "save-appdir",
            ["sh", "-c", "mkdir -p '" + configDir + "' && echo '" + appImageDir + "' > '" + appImageDirFile + "'"],
            null,
            0,
            5000
        );
    }

    function loadSavedDesktopApps(callback) {
        Proc.runCommand(
            "load-desktop",
            ["sh", "-c", "cat '" + savedAppsFile + "' 2>/dev/null || echo '[]'"],
            function(output, exitCode) {
                var saved = [];
                if (exitCode === 0 && output && output.trim().length > 0) {
                    try {
                        saved = JSON.parse(output.trim());
                        if (!Array.isArray(saved)) saved = [];
                    } catch (e) { saved = []; }
                }
                if (callback) callback(saved);
            },
            0,
            5000
        );
    }

    function launchApp(appPath) {
        var cmd;
        if (appPath.endsWith(".AppImage")) {
            cmd = "'" + appPath + "' --no-sandbox &";
        } else {
            cmd = "gtk-launch '" + appPath.replace(/\.desktop$/, "") + "' 2>/dev/null || '" + appPath + "' &";
        }
        Proc.runCommand("launch", ["sh", "-c", cmd], null, 0, 5000);
    }

    function openDirectoryPicker() {
        var browser = FileBrowserSurface {};
        browser.title = I18n.tr("Select Directory");
        browser.folderMode = true;
        browser.onAccepted.connect(function(selectedPath) {
            if (selectedPath && selectedPath.length > 0) {
                appImageDir = selectedPath;
                saveAppImageDir();
                scanApps();
            }
            browser.close();
        });
        browser.open();
    }

    function init() {
        if (initialized) return;
        initialized = true;
        loadIconSize();
        loadAppImageDir();
        scanApps();
    }

    Component.onCompleted: {
        Qt.callLater(init);
    }

    Column {
        id: contentColumn
        width: parent ? parent.width : 700
        spacing: Theme.spacingM

        Row {
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: I18n.tr("Programs") + " (" + root.appCount + ")"
                font.pixelSize: Theme.fontSizeLarge
                font.bold: true
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            Item { width: 0; height: 0 }

            DankIcon {
                iconName: "folder_open"
                size: Theme.iconSizeS
                color: Theme.surfaceVariantText
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.openDirectoryPicker()
                    cursorShape: Qt.PointingHandCursor
                }
            }

            DankIcon {
                iconName: "font_download"
                size: Theme.iconSizeS
                color: Theme.surfaceVariantText
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.iconSize = root.iconSize === 36 ? 48 : (root.iconSize === 48 ? 64 : 36)
                    cursorShape: Qt.PointingHandCursor
                }
            }
        }

        StyledText {
            text: root.appImageDir
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            visible: !root.extractingIcons
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS
            visible: root.extractingIcons

            DSpinner { size: 12; anchors.verticalCenter: parent.verticalCenter }
            StyledText {
                text: (root.appImageApps.length - root.extractDone) + " / " + root.extractTotal
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Flickable {
            width: parent.width
            height: Math.min(400, _columns * _cellHeight + 20)
            clip: true
            contentHeight: contentColumn.height > height ? contentColumn.height : height

            GridView {
                id: appGrid
                width: parent.width
                height: parent.contentHeight
                cellWidth: iconSize + 16
                cellHeight: _cellHeight
                columns: _columns
                model: root.appImageApps.length + root.desktopAppsList.length

                delegate: Item {
                    width: appGrid.cellWidth
                    height: appGrid.cellHeight
                    property var appData: index < root.appImageApps.length ? root.appImageApps[index] : root.desktopAppsList[index - root.appImageApps.length]

                    Column {
                        anchors.centerHorizontally: parent.horizontalCenter
                        spacing: 4

                        Rectangle {
                            width: root.iconSize + 4
                            height: root.iconSize + 4
                            radius: Theme.cornerRadiusS
                            color: "transparent"
                            border.color: mouseArea.containsMouse ? Theme.outlineMedium : "transparent"
                            border.width: 1

                            Image {
                                anchors.centerIn: parent
                                width: root.iconSize
                                height: root.iconSize
                                source: appData.iconPath !== "" ? appData.iconPath : ""
                                fillMode: Image.PreserveAspectFit
                                visible: source !== ""
                            }

                            DankIcon {
                                anchors.centerIn: parent
                                size: root.iconSize
                                iconName: "extension"
                                color: Theme.surfaceVariantText
                                visible: parent.children[1].visible === false
                            }
                        }

                        StyledText {
                            width: parent.parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: appData.name.length > 14 ? appData.name.substring(0, 12) + "…" : appData.name
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                            maximumLineCount: 2
                        }

                        MouseArea {
                            id: mouseArea
                            anchors.fill: parent.parent
                            onClicked: root.launchApp(appData.path)
                            cursorShape: Qt.PointingHandCursor
                        }
                    }
                }
            }
        }

        Item { id: focusGrabber; focus: true }
    }
}
