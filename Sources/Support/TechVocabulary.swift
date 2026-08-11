import Foundation

/// Built-in technical vocabulary fed to the recognizer as contextual strings.
///
/// These are terms speech-to-text reliably mangles: names that get split
/// ("git hub"), acronyms that arrive as separate letters ("a p i"), and words
/// with conventional capitalization no general model would guess
/// ("PostgreSQL"). Biasing the recognizer fixes them at the source, which is
/// cheaper and more reliable than asking the rewrite model to reconstruct what
/// was meant from a mangled spelling.
///
/// Kept separate from the user's own dictionary so it can be switched off, and
/// so their personal entries stay theirs.
enum TechVocabulary {

    static let terms: [String] = [
        // Version control and collaboration
        "GitHub", "GitLab", "Bitbucket", "git", "pull request", "merge request",
        "code review", "merge conflict", "rebase", "cherry-pick", "squash",
        "stash", "commit", "diff", "branch", "monorepo", "repo", "fork",
        "upstream", "changelog", "blame", "bisect", "submodule",

        // Languages and runtimes
        "Swift", "SwiftUI", "AppKit", "UIKit", "Objective-C", "TypeScript",
        "JavaScript", "Python", "Rust", "Go", "Golang", "Kotlin", "Java",
        "Ruby", "PHP", "Elixir", "Scala", "Haskell", "C++", "C#", "Node",
        "Deno", "Bun", "WebAssembly",

        // Frameworks and tooling
        "React", "Vue", "Svelte", "Angular", "Next.js", "Tailwind", "Django",
        "Flask", "FastAPI", "Rails", "Express", "Vite", "Webpack", "ESLint",
        "Prettier", "npm", "pnpm", "Yarn", "Homebrew", "Xcode", "VS Code",
        "IntelliJ", "Vim", "Neovim", "tmux", "SwiftPM", "CocoaPods", "XcodeGen",

        // Infrastructure and cloud
        "Docker", "Kubernetes", "kubectl", "Terraform", "Ansible", "Jenkins",
        "nginx", "Apache", "AWS", "Azure", "GCP", "Cloudflare", "Vercel",
        "Netlify", "Heroku", "S3", "EC2", "Lambda", "serverless", "container",
        "load balancer", "autoscaling", "canary", "blue-green", "rollback",
        "hotfix", "staging", "production", "deploy", "provisioning",

        // Data
        "Postgres", "PostgreSQL", "MySQL", "SQLite", "Redis", "MongoDB",
        "Elasticsearch", "Kafka", "RabbitMQ", "schema", "migration", "index",
        "query", "transaction", "sharding", "replica", "failover", "ORM",
        "CRUD", "primary key", "foreign key", "JOIN",

        // Protocols, formats, acronyms
        "API", "SDK", "CLI", "GUI", "IDE", "JSON", "YAML", "TOML", "XML",
        "HTML", "CSS", "SQL", "HTTP", "HTTPS", "REST", "GraphQL", "gRPC",
        "WebSocket", "webhook", "OAuth", "JWT", "SSO", "SAML", "TLS", "SSL",
        "SSH", "DNS", "CDN", "VPN", "URL", "URI", "UUID", "regex", "UTF-8",
        "base64", "endpoint", "payload", "middleware", "idempotent",

        // Testing and quality
        "unit test", "integration test", "end-to-end", "linter", "mock",
        "stub", "fixture", "snapshot", "code coverage", "flaky test",
        "regression", "stack trace", "breakpoint", "race condition",
        "deadlock", "memory leak", "null pointer", "segfault", "tech debt",

        // Process
        "CI", "CD", "CI/CD", "sprint", "standup", "retro", "backlog", "epic",
        "story point", "roadmap", "spec", "RFC", "ADR", "SLA", "SLO", "QA",
        "UX", "UI", "MVP", "feature flag", "A/B test", "postmortem",
        "on-call", "runbook", "observability", "telemetry", "latency",
        "throughput", "p95", "p99",

        // AI and ML
        "LLM", "ASR", "TTS", "GPT", "Claude", "Anthropic", "OpenAI",
        "Hugging Face", "transformer", "embedding", "fine-tune", "inference",
        "quantization", "GGUF", "llama.cpp", "Ollama", "MLX", "RAG",
        "context window", "prompt injection", "hallucination", "token",
        "temperature", "top-p", "tokenizer", "checkpoint", "GPU", "CPU",

        // Apple platform
        "macOS", "iOS", "iPadOS", "visionOS", "watchOS", "TestFlight",
        "App Store", "Core Data", "Core Audio", "Metal", "Keychain",
        "Accessibility API", "entitlement", "provisioning profile",
        "notarization", "code signing", "bundle identifier",
    ]
}
