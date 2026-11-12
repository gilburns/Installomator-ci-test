#!/bin/bash
# lint_label.sh — static checks for Installomator label files (fragments/labels/*.sh)
#
# Usage: utils/lint_label.sh [-q] [-g] file.sh [file.sh ...]
#   -q   quiet: only print ERROR lines and the summary
#   -g   GitHub Actions: print findings as workflow annotations
#        (::error / ::warning / ::notice) and require zsh for the syntax check
#
# Checks .editorconfig formatting (LF, final newline, no trailing whitespace,
# 4-space indent, no tabs), label structure, required variables, and
# commands/flags that are unavailable or unreliable on older supported macOS.
# Exit status: 0 = no errors, 1 = at least one ERROR, 2 = usage.
#
# Levels: ERROR fails the check; WARN and INFO are reported for review.
#
# Written for bash 3.2 (macOS /bin/bash) and BSD/GNU awk alike. Set AWK to
# choose the awk binary (default: awk).

AWK=${AWK:-awk}
quiet=0
github=0
while [ $# -gt 0 ]; do
    case "$1" in
        -q) quiet=1; shift ;;
        -g) github=1; shift ;;
        --) shift; break ;;
        -*) echo "usage: $0 [-q] [-g] label.sh [label.sh ...]" >&2; exit 2 ;;
        *) break ;;
    esac
done
if [ $# -eq 0 ]; then
    echo "usage: $0 [-q] [-g] label.sh [label.sh ...]" >&2
    exit 2
fi

have_zsh=0
if command -v zsh >/dev/null 2>&1; then have_zsh=1; fi
if [ $github -eq 1 ] && [ $have_zsh -eq 0 ]; then
    echo "::error title=lint_label.sh::zsh is required for the label syntax check"
    exit 2
fi

# Print findings ("file:line: LEVEL: message") in the selected output mode.
emit() {
    if [ $github -eq 1 ]; then
        "$AWK" '{
            if (!match($0, /:[0-9]+: (ERROR|WARN|INFO): /)) { print; next }
            file = substr($0, 1, RSTART - 1)
            rest = substr($0, RSTART + 1)
            n = index(rest, ":"); ln = substr(rest, 1, n - 1); rest = substr(rest, n + 2)
            n = index(rest, ":"); lvl = substr(rest, 1, n - 1); msg = substr(rest, n + 2)
            cmd = "notice"
            if (lvl == "ERROR") cmd = "error"
            else if (lvl == "WARN") cmd = "warning"
            gsub(/%/, "%25", msg); gsub(/\r/, "%0D", msg)
            gsub(/%/, "%25", file); gsub(/\r/, "%0D", file); gsub(/:/, "%3A", file); gsub(/,/, "%2C", file)
            loc = "file=" file
            if (ln + 0 > 0) loc = loc ",line=" ln
            printf "::%s %s,title=lint_label %s::%s\n", cmd, loc, lvl, msg
        }'
    elif [ $quiet -eq 1 ]; then
        grep ': ERROR: '
    else
        cat
    fi
}

total_errors=0
total_warns=0
files=0

for f in "$@"; do
    files=$((files + 1))
    if [ ! -f "$f" ]; then
        printf '%s:0: ERROR: file not found\n' "$f" | emit
        total_errors=$((total_errors + 1))
        continue
    fi

    out=$("$AWK" -v FILE="$f" -v SQ="'" '
    function report(level, ln, msg) {
        printf "%s:%d: %s: %s\n", FILE, ln, level, msg
        if (level == "ERROR") errs++
        else if (level == "WARN") warns++
    }
    function strip_comment(s,   i, c, q) {
        # crude: drop text after a # that is preceded by whitespace and not inside quotes
        q = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (q == "" && (c == "\"" || c == SQ)) q = c
            else if (q != "" && c == q) q = ""
            else if (q == "" && c == "#" && (i == 1 || substr(s, i-1, 1) ~ /[ \t]/)) return substr(s, 1, i-1)
        }
        return s
    }
    BEGIN {
        errs = 0; warns = 0; in_header = 1; header_done = 0; label = ""
        valid_types = " dmg pkg zip tbz bz2 pkgInDmg pkgInZip appInDmgInZip pkgInDmgInZip updateronly "
        appless_types = " dmg zip tbz bz2 appInDmgInZip "
        git_line = 0; archive_after_git = 0
    }
    {
        raw = $0
        lines[NR] = raw
        if (raw ~ /\r/) { report("ERROR", NR, "CRLF line ending (editorconfig: end_of_line = lf)"); sub(/\r$/, "", raw) }
        if (raw ~ /\t/) report("ERROR", NR, "tab character (editorconfig: indent_style = space)")
        if (raw ~ /[ \t]+$/) report("ERROR", NR, "trailing whitespace (editorconfig: trim_trailing_whitespace = true)")

        if (NR == 1 && raw ~ /^#!/) { report("ERROR", NR, "labels must not have a shebang"); next }

        # ---- header (label name lines) ----
        if (in_header) {
            if (raw ~ /^[a-z0-9_-]+\|\\$/ || raw ~ /^[a-z0-9_-]+\)$/) {
                nm = raw; sub(/(\|\\|\))$/, "", nm)
                if (label == "") label = nm
                names = names " " nm
                if (raw ~ /\)$/) { in_header = 0; header_done = 1 }
                next
            } else if (raw ~ /^[^ \t#].*(\\|\))$/) {
                # header line that zsh may accept but does not follow the convention
                nm = raw; sub(/[ ]*(\|[ ]*\\|\))$/, "", nm)
                if (nm ~ /^[A-Za-z0-9_.-]+$/ && nm !~ /^[a-z0-9_-]+$/)
                    report("ERROR", NR, "label name must use only lowercase a-z, 0-9, - and _ (got: " nm ")")
                else
                    report("ERROR", NR, "label header line \"" raw "\" should be exactly name|\\ (alias line) or name) (last line), no spaces")
                if (label == "" && nm ~ /^[A-Za-z0-9_.-]+$/) label = nm
                if (nm ~ /^[A-Za-z0-9_.-]+$/) names = names " " nm
                if (raw ~ /\)$/) { in_header = 0; header_done = 1 }
                next
            } else {
                report("ERROR", NR, "expected the label name followed by \")\" at column 0 (aliases as name|\\ lines)")
                in_header = 0; header_done = 1
                # fall through and treat as body
            }
        }

        # ---- body ----
        if (raw ~ /^[ \t]*$/) { blank_run++; next }
        blank_run = 0
        lastln = NR; last = raw

        match(raw, /^ */); ind = RLENGTH
        if (raw !~ /^\t/ && raw !~ /^[ ]*;;[ ]*$/) {
            if (ind == 0) report("ERROR", NR, "body line not indented (labels are indented 4 spaces inside the case branch)")
            else if (ind % 4 != 0) report("WARN", NR, "indent of " ind " spaces is not a multiple of 4 (editorconfig: indent_size = 4)")
        }

        trimmed = raw; sub(/^[ \t]+/, "", trimmed)
        is_comment = (trimmed ~ /^#/)

        if (is_comment) {
            if (trimmed ~ /^#[ ]*(downloadURL|appNewVersion|name|type|expectedTeamID|archiveName|appName)=/)
                report("WARN", NR, "commented-out assignment; remove dead code before submitting")
            else if (tolower(trimmed) ~ /credit|contributed by|thanks to|^# *(by|author) /)
                report("WARN", NR, "credit/author comment; CONTRIBUTING asks not to add these to labels")
            else
                report("WARN", NR, "comment line in label; labels are kept free of comments to keep Installomator.sh short")
            next
        }

        code = strip_comment(trimmed)
        if (code != trimmed)
            report("WARN", NR, "trailing comment in label; labels are kept free of comments to keep Installomator.sh short")

        # assignments
        if (match(code, /^[A-Za-z_][A-Za-z0-9_]*(\+)?=/)) {
            var = substr(code, 1, RLENGTH - 1); sub(/\+$/, "", var)
            val = substr(code, RLENGTH + 1)
            seen[var] = NR
            if (raw ~ /\\$/) {
                if (var ~ /^(name|type|downloadURL|appNewVersion|expectedTeamID|archiveName|appName|packageID)$/)
                    report("ERROR", NR, var "= continues onto the next line with \\; each assignment must be one physical line")
                else
                    report("WARN", NR, "line continuation (\\) in an assignment; keep each assignment on one line")
            }
            if (var == "type") {
                t = val; gsub(/"/, "", t); gsub(SQ, "", t)
                types[NR] = t
                if (index(valid_types, " " t " ") == 0 && t !~ /^\$/)
                    report("ERROR", NR, "type=\"" t "\" is not a valid type (case-sensitive: dmg pkg zip tbz bz2 pkgInDmg pkgInZip appInDmgInZip pkgInDmgInZip updateronly)")
                last_type = t
            }
            if (var == "expectedTeamID") {
                tid = val; gsub(/"/, "", tid); gsub(SQ, "", tid)
                if (tid == "Software Update")
                    report("INFO", NR, "expectedTeamID \"Software Update\" is only correct for Apple-signed pkgs (no Team ID in the spctl origin)")
                else if (tid !~ /^\$/ && tid !~ /^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$/)
                    report("WARN", NR, "expectedTeamID \"" tid "\" is not a 10-character Team ID; only valid for legacy certificates whose spctl origin has no (TEAMID) — verify with spctl -a -vv")
                if (val !~ ("^[\"" SQ "]"))
                    report("WARN", NR, "quote the expectedTeamID value: expectedTeamID=\"" tid "\"")
            }
            if (var ~ /^(blockingProcesses|curlOptions)$/ && val !~ /^\(/)
                report("WARN", NR, var " should be an array: " var "=( ... )")
            if (var ~ /^(updateToolArguments|CLIArguments)$/ && val !~ /^\(/)
                report("INFO", NR, var " is usually written as an array: " var "=( ... )")
            if (var == "archiveName" && git_line > 0) archive_after_git = NR
            if (var == "downloadURL" && val ~ /^"?http:\/\//)
                report("WARN", NR, "downloadURL uses http://; use https:// if the vendor supports it")
        }
        if (code ~ /^(appCustomVersion|function appCustomVersion)/) {
            seen["appCustomVersion"] = NR
            if (code !~ /\}[ ]*$/) report("WARN", NR, "appCustomVersion should be a one-line function: appCustomVersion(){ ... }")
        }

        if (code ~ /downloadURLFromGit/ && git_line == 0) git_line = NR
        # arm64-only if-blocks: need an else/elif unless downloadURL is also set outside the block
        if (code ~ /^if .*arch\)"?[ ]*==[ ]*"?arm64/ && code !~ /[; ]fi[ ;]*$/ && arm_line == 0) { arm_line = NR; in_arm = 1; arm_depth = 0 }
        else if (in_arm && code ~ /^if[ ]/) arm_depth++
        else if (in_arm && arm_depth == 0 && code ~ /^(else|elif)([ ;]|$)/) { arm_other = 1; in_arm = 0 }
        else if (in_arm && code ~ /^fi([ ;]|$)/) { if (arm_depth == 0) in_arm = 0; else arm_depth-- }
        else if (!in_arm && code ~ /^downloadURL=/) url_outside = 1

        # ---- commands / compatibility ----
        # cmd: code with single-quoted text (awk/sed programs, literals) blanked out,
        # used for checks that look for a command name in command position.
        cmd = code; gsub(SQ "[^" SQ "]*" SQ, SQ SQ, cmd)
        CP = "(^|[|;&(]|\\$\\(|then|do|else)[ ]*(/usr/bin/|/usr/local/bin/|/opt/homebrew/bin/)?"
        if (cmd ~ (CP "jq([ ]|$)"))
            report("ERROR", NR, "jq is only present on macOS 15+; use getJSONValue \"$json\" \"key.path\"")
        if (cmd ~ (CP "python[0-9.]*([ ]|$)"))
            report("ERROR", NR, "python is not available on current macOS (removed 12.3); use getJSONValue / xpath / sed")
        if (cmd ~ (CP "(perl|ruby)[ ]+-"))
            report("WARN", NR, "perl/ruby one-liners rely on deprecated bundled runtimes; use sed -E / awk / zsh expansion")
        if (code ~ /\/usr\/bin\/xpath/)
            report("WARN", NR, "call the xpath wrapper function, not /usr/bin/xpath (it handles the Big Sur -e change)")
        if (code ~ /(^|[ |;(])xpath[ ]+-e/)
            report("ERROR", NR, "xpath -e breaks on Catalina and earlier; the xpath wrapper adds -e only when needed")
        if (code ~ /grep[ ]+(-[A-Za-z]*P|--perl)/)
            report("ERROR", NR, "grep -P (PCRE) is not supported by macOS grep; use grep -E / sed -E")
        if (code ~ /sed[ ]+(-[A-Za-z]*r|--regexp-extended)/)
            report("WARN", NR, "use sed -E (house style, BSD-safe) instead of sed -r")
        if (code ~ /sed[ ]+(-[A-Za-z]*i)/)
            report("WARN", NR, "sed -i edits files in place; labels should not need it (and BSD/GNU syntax differ)")
        if (code ~ /plutil[^|]*-extract[^|]*[ ]raw/)
            report("ERROR", NR, "plutil -extract ... raw requires macOS 12+; use getJSONValue for JSON, or defaults read / PlistBuddy for plists")
        if (cmd ~ (CP "readlink[ ]+-[A-Za-z]*f") || cmd ~ (CP "realpath([ ]|$)"))
            report("ERROR", NR, "readlink -f / realpath are missing on older macOS; use the zsh :A modifier (${path:A})")
        if (cmd ~ (CP "date[ ]+(-[A-Za-z]*d|--date)"))
            report("ERROR", NR, "GNU date -d is not available; use date -j -f <fmt> <string> +<outfmt>")
        if (code ~ /head[ ]+-n[ ]*-[0-9]/ || code ~ /head[ ]+--lines=-/)
            report("ERROR", NR, "negative head -n is GNU-only; use sed " SQ "$d" SQ " or awk")
        if (cmd ~ (CP "tac([ ]|$)"))
            report("ERROR", NR, "tac does not exist on macOS; use tail -r")
        if (code ~ /gensub[ ]*\(|IGNORECASE/)
            report("ERROR", NR, "GNU awk feature (gensub/IGNORECASE); macOS awk is BWK awk")
        if (code ~ /--fail-with-body|--retry-all-errors|--no-progress-meter|%\{json\}/)
            report("ERROR", NR, "curl option newer than macOS 10.14'"'"'s curl 7.54")
        if (code ~ /base64[ ]+(-d|--decode)/)
            report("WARN", NR, "base64 -d is not accepted on older macOS; use base64 -D (or avoid)")
        if (code ~ /uname[ ]+-m/)
            report("INFO", NR, "house convention for architecture is [[ $(arch) == \"arm64\" ]] / elif [[ $(arch) == \"i386\" ]]")
        if (code ~ /api\.github\.com\/repos\/[^\/]+\/[^\/]+\/releases\/latest/)
            report("INFO", NR, "consider downloadURLFromGit / versionFromGit instead of querying the GitHub API directly")
        if (cmd ~ (CP "exit([ ;]|$)") && code !~ /(^|[^a-z])awk[ ]/)
            report("ERROR", NR, "do not call exit in a label; use cleanupAndExit <code> \"message\" ERROR")
        if (cmd ~ (CP "(eval|source)[ ]"))
            report("ERROR", NR, "eval/source in a label; never execute or source vendor responses or downloaded content")
        if (cmd ~ (CP "local[ ]") && cmd !~ /appCustomVersion/)
            report("WARN", NR, "local outside a function; drop it at label level")
        if (code ~ /(^|[ |;(])curl[ ]/ && code !~ /curl[^|]*(-[A-Za-z]*f[A-Za-z]*|--fail)([ ]|$)/)
            report("INFO", NR, "curl without -f/--fail: HTTP errors will be parsed as content")
    }
    END {
        if (lastln == 0) { report("ERROR", 1, "file has no label body"); print "##", errs, warns, label names; exit }
        if (last != "    ;;")
            report("ERROR", lastln, "label must end with a line of exactly four spaces and ;; (got: \"" last "\")")
        if (blank_run > 0)
            report("WARN", NR, "blank line(s) after ;; (exactly one final newline expected)")
        split("name type downloadURL expectedTeamID", req, " ")
        for (i = 1; i <= 4; i++) if (!(req[i] in seen)) report("ERROR", 1, "required variable " req[i] " is not set")
        if (!("appNewVersion" in seen)) report("WARN", 1, "appNewVersion is not set; maintainers expect it (or a documented reason it cannot be determined)")
        if (("packageID" in seen) && index(appless_types, " " last_type " ") > 0)
            report("WARN", seen["packageID"], "packageID on a drag-and-drop type (" last_type "); it is meant for pkg installs that do not place an app in /Applications")
        if (arm_line > 0 && !arm_other && !url_outside)
            report("ERROR", arm_line, "arm64 branch with no else/elif: Intel Macs fall through unhandled. Add an i386 branch, or for Apple-Silicon-only apps: else printlog ... ERROR; cleanupAndExit 95 \"<App> requires Apple Silicon\" ERROR")
        if (archive_after_git)
            report("WARN", archive_after_git, "archiveName is set after downloadURLFromGit; set it before so it selects the release asset")
        print "##", errs, warns, label names
    }
    ' "$f")

    summary=$(printf '%s\n' "$out" | tail -1)
    body=$(printf '%s\n' "$out" | sed '$d')
    read -r _ ferrs fwarns flabel fnames <<EOF
$summary
EOF
    ferrs=${ferrs:-1}; fwarns=${fwarns:-0}

    # final newline (awk cannot see this)
    if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then
        body="${body:+$body
}$f:0: ERROR: missing final newline (editorconfig: insert_final_newline = true)"
        ferrs=$((ferrs + 1))
    fi

    # file name should match one of the label names in the header
    base=$(basename "$f" .sh)
    case " $fnames " in
        *" $base "*) ;;
        *)
            if [ -n "$flabel" ] && [ "$base" != "$(basename "$f")" ]; then
                body="${body:+$body
}$f:1: WARN: file name \"$base.sh\" does not match a label name in its header (expected fragments/labels/$flabel.sh)"
                fwarns=$((fwarns + 1))
            fi
            ;;
    esac

    # zsh syntax check, when zsh is available
    if [ $have_zsh -eq 1 ]; then
        synerr=$( { printf 'case $label in\n'; cat "$f"; printf 'esac\n'; } | zsh -n 2>&1 )
        if [ -n "$synerr" ]; then
            body="${body:+$body
}$f:0: ERROR: zsh -n syntax check failed: $(printf '%s' "$synerr" | head -3 | tr '\n' ' ')"
            ferrs=$((ferrs + 1))
        fi
    fi

    if [ -n "$body" ]; then
        printf '%s\n' "$body" | emit
    fi
    total_errors=$((total_errors + ferrs))
    total_warns=$((total_warns + fwarns))
done

echo "-- $files file(s): $total_errors error(s), $total_warns warning(s)"
[ $total_errors -eq 0 ]
