on run arguments
    if (count of arguments) is not 9 and (count of arguments) is not 10 then
        error "expected mount path, app name, icon size, window size, icon positions, and optional configure/verify mode"
    end if

    set mountPath to item 1 of arguments
    set appItemName to item 2 of arguments
    set requestedIconSize to (item 3 of arguments) as integer
    set windowWidth to (item 4 of arguments) as integer
    set windowHeight to (item 5 of arguments) as integer
    set appIconX to (item 6 of arguments) as integer
    set appIconY to (item 7 of arguments) as integer
    set applicationsIconX to (item 8 of arguments) as integer
    set applicationsIconY to (item 9 of arguments) as integer
    set operationMode to "configure"
    if (count of arguments) is 10 then
        set operationMode to item 10 of arguments
    end if
    if operationMode is not "configure" and operationMode is not "verify" then
        error "layout mode must be configure or verify"
    end if

    tell application "Finder"
        set targetWindowValidated to false
        set targetWindow to missing value
        try
            set targetFolder to POSIX file mountPath as alias
            open targetFolder
            delay 1

            set targetWindow to front window
            if (target of targetWindow as alias) is not targetFolder then
                error "Finder opened an unexpected window for " & mountPath
            end if
            set targetWindowValidated to true

            if my operationMode is "configure" then
                set current view of targetWindow to icon view
                set toolbar visible of targetWindow to false
                set statusbar visible of targetWindow to false
                set the bounds of targetWindow to {100, 100, 100 + my windowWidth, 100 + my windowHeight}

                tell icon view options of targetWindow
                    set arrangement to not arranged
                    set icon size to my requestedIconSize
                    set text size to 16
                end tell

                set position of item (my appItemName) of target of targetWindow to {my appIconX, my appIconY}
                set position of item "Applications" of target of targetWindow to {my applicationsIconX, my applicationsIconY}

                -- Finder does not reliably persist icon-view settings merely by
                -- closing a mounted-volume window. Reopen it in the same Finder
                -- transaction and briefly change its bounds to force .DS_Store
                -- serialization before the separate verification pass.
                close targetWindow
                delay 1
                open targetFolder
                delay 1
                set targetWindow to front window
                if (target of targetWindow as alias) is not targetFolder then
                    error "Finder reopened an unexpected window for " & mountPath
                end if
                set position of item (my appItemName) of target of targetWindow to {my appIconX, my appIconY}
                set position of item "Applications" of target of targetWindow to {my applicationsIconX, my applicationsIconY}
                set the bounds of targetWindow to {100, 100, 90 + my windowWidth, 90 + my windowHeight}
                delay 1
                set the bounds of targetWindow to {100, 100, 100 + my windowWidth, 100 + my windowHeight}
                delay 3
            end if

            set actualIconSize to icon size of icon view options of targetWindow
            set actualTextSize to text size of icon view options of targetWindow
            set actualBounds to bounds of targetWindow
            set actualWindowWidth to (item 3 of actualBounds) - (item 1 of actualBounds)
            set actualWindowHeight to (item 4 of actualBounds) - (item 2 of actualBounds)
            set actualAppPosition to position of item (my appItemName) of target of targetWindow
            set actualApplicationsPosition to position of item "Applications" of target of targetWindow

            if current view of targetWindow is not icon view then
                error "DMG Finder window is not using icon view"
            end if
            if toolbar visible of targetWindow is not false then
                error "DMG Finder toolbar is visible"
            end if
            if statusbar visible of targetWindow is not false then
                error "DMG Finder status bar is visible"
            end if
            if actualIconSize is not my requestedIconSize then
                error "DMG icon size is " & actualIconSize & " instead of " & my requestedIconSize
            end if
            if actualTextSize is not 16 then
                error "DMG text size is " & actualTextSize & " instead of 16"
            end if
            if actualWindowWidth is not my windowWidth or actualWindowHeight is not my windowHeight then
                error "DMG window size is " & actualWindowWidth & "x" & actualWindowHeight & " instead of " & my windowWidth & "x" & my windowHeight
            end if
            if (item 1 of actualAppPosition as integer) is not my appIconX or (item 2 of actualAppPosition as integer) is not my appIconY then
                error "DMG app icon position is {" & (item 1 of actualAppPosition) & ", " & (item 2 of actualAppPosition) & "} instead of {" & my appIconX & ", " & my appIconY & "}"
            end if
            if (item 1 of actualApplicationsPosition as integer) is not my applicationsIconX or (item 2 of actualApplicationsPosition as integer) is not my applicationsIconY then
                error "DMG Applications icon position is {" & (item 1 of actualApplicationsPosition) & ", " & (item 2 of actualApplicationsPosition) & "} instead of {" & my applicationsIconX & ", " & my applicationsIconY & "}"
            end if

            close targetWindow
            delay 1
        on error errorMessage number errorNumber
            if targetWindowValidated then
                try
                    close targetWindow
                end try
            end if
            error errorMessage number errorNumber
        end try
    end tell

    return actualIconSize as text
end run
