import Foundation

/// Which approvals deserve a second look when answered from outside the chat (the Lock Screen, a
/// notification): writes, deletes and spends, and anything the gateway's guardian flagged. Reads
/// and lookups apply at once, so the second question stays rare enough to keep meaning something.
public enum ApprovalRisk {
    public static func isRisky(_ a: ApprovalRequest) -> Bool {
        if a.smartDenied == true { return true }
        let tool = (a.toolName ?? "").lowercased()
        if riskyTools.contains(tool) { return true }
        if readOnlyTools.contains(tool), (a.command ?? "").isEmpty { return false }
        let label = (a.description ?? "").lowercased()
        if labelSignals.contains(where: { label.contains($0) }) { return true }
        let key = (a.patternKey ?? "").lowercased()
        if keySignals.contains(where: { key.contains($0) }) { return true }
        if let cmd = a.command, !cmd.isEmpty { return commandIsRisky(cmd) }
        return false
    }

    /// Tools that change files or run arbitrary code.
    static let riskyTools: Set<String> = ["write_file", "edit_file", "delete_file", "apply_patch", "patch", "execute_code", "notebook_edit", "move_file", "rename_file", "create_file"]
    /// Tools that only look.
    static let readOnlyTools: Set<String> = ["read_file", "search_files", "list_files", "glob", "grep", "web_search", "web_extract", "web_fetch", "skill_view", "tool_search", "get_page", "screenshot"]

    /// Words in the gateway's danger label (or the bot's description of the action) that mean a
    /// write, a delete, a spend, a privilege or a leak.
    static let labelSignals: [String] = [
        "delet", "remov", "wipe", "format", "overwrit", "truncat", "shred", "destroy", "destructive", "recursive",
        "write", "modif", "chang", "install", "uninstall", "upgrade", "deploy", "publish", "push", "reset", "rebase", "clean",
        "kill", "force", "stop", "restart", "reboot", "shutdown", "permission", "chmod", "chown", "sudo", "root", "privileg",
        "shadow", "backup", "registry", "boot", "service", "disk", "partition", "block device", "drop", "migrat",
        "pay", "purchas", "charg", "buy", "spend", "transfer", "billing", "invoice", "order", "checkout", "subscri",
        "secret", "ssh key", "credential", "token", "password", "remote content", "encoded command", "pipe",
        "send", "email", "post", "upload", "exfil",
    ]
    static let keySignals: [String] = ["rm", "del", "write", "edit", "patch", "exec", "sudo", "chmod", "chown", "kill", "dd", "mkfs", "git push", "git reset", "install", "curl", "wget", "pay", "stripe"]

    /// The command itself: read-only shapes pass, anything that writes, deletes, installs,
    /// escalates, sends or spends asks.
    static func commandIsRisky(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in riskyCommandPatterns where c.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    static let riskyCommandPatterns: [String] = [
        #"(^|[;&|`(]\s*)(sudo|doas|su)\b"#,
        #"\b(rm|rmdir|unlink|shred|wipe|srm)\b"#,
        #"\bfind\b.*(\s-delete\b|\s-exec\s+(rm|mv|chmod|chown|shred)\b)"#,
        #"\b(dd|mkfs(\.\w+)?|fdisk|parted|diskutil\s+(erase|partition|zero)|wipefs|truncate|fallocate)\b"#,
        #"\b(mv|cp|rsync|install|ln)\b"#,
        #"(^|[^>])>{1,2}\s*[^&\s]"#,                       // redirection into a file
        #"\btee\b"#,
        #"\b(sed|perl)\b[^|]*\s-[a-z]*i\b"#,               // in-place edits
        #"\b(chmod|chown|chgrp|setfacl|icacls)\b"#,
        #"\b(kill|pkill|killall|taskkill|stop-process)\b"#,
        #"\b(systemctl|launchctl|service|sc(\.exe)?)\s+(start|stop|restart|reload|enable|disable|delete|unload|load|kickstart)\b"#,
        #"\b(reboot|shutdown|halt|poweroff|init\s+[06])\b"#,
        #"\bcrontab\b\s+(-r|-e|[^-\s])"#,
        #"\bgit\s+(push|reset|checkout\s+--|restore|clean|rebase|merge|cherry-pick|revert|commit|stash\s+(drop|clear|pop)|branch\s+-[dD]|tag\s+-d|filter-branch|filter-repo|gc\s+--prune|remote\s+(add|remove|set-url)|config)\b"#,
        #"\b(pip3?|pipx|uv|npm|pnpm|yarn|bun|gem|cargo|go|brew|apt(-get)?|yum|dnf|pacman|apk|snap|flatpak|choco|winget|conda|poetry)\s+(install|uninstall|remove|purge|upgrade|update|add|rm|dist-upgrade|autoremove|link|publish)\b"#,
        #"\b(docker|podman|nerdctl)\s+(rm|rmi|prune|system\s+prune|volume\s+(rm|prune)|network\s+(rm|prune)|kill|stop|restart|push|run|exec|compose\s+(down|up|rm))\b"#,
        #"\bkubectl\s+(delete|apply|create|replace|patch|edit|rollout|scale|drain|cordon|taint|exec)\b"#,
        #"\b(terraform|tofu|pulumi)\s+(apply|destroy|import|taint|state)\b"#,
        #"\b(aws|gcloud|az|doctl|linode-cli|flyctl|fly|heroku|vercel|netlify|wrangler)\b.*\b(create|delete|terminate|run-instances|deploy|publish|put-|update|start|stop|reboot|resize|purchase|buy)\b"#,
        #"\b(curl|wget|http|https|xh)\b.*(\s-X\s*(POST|PUT|PATCH|DELETE)|\s-(d|F|T)\s|\s--(data|form|upload-file|json|method)\b|\|\s*(sh|bash|zsh|python\d?|node|iex)\b)"#,
        #"\b(mail|mailx|sendmail|mutt|msmtp|osascript)\b"#,
        #"\b(stripe|paypal|braintree|square|coinbase|wise|revolut)\b|\b(pay|purchase|checkout|charge|refund|transfer|withdraw|top-?up)\b"#,
        #"\b(psql|mysql|sqlite3|mongo(sh)?|redis-cli)\b.*\b(drop|delete|truncate|update|insert|alter|flushall|flushdb|del)\b"#,
        #"\b(ssh|scp|sftp)\b.*\b(rm|mv|dd|sudo|reboot|kill)\b"#,
        #"\b(defaults\s+write|sysctl\s+-w|nvram|pmset|networksetup|scutil\s+--set)\b"#,
        #"(~|\$HOME|/root|/home/\w+)/\.(ssh|aws|gnupg|config/gh|netrc|hermes)\b"#,
        #"\.(env|pem|key|p12|keychain)\b"#,
    ]
}
